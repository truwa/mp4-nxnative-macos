import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The three appearance icons in every launcher window's title bar: system, light, dark.
struct AppearanceButtons: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                button("system", "circle.lefthalf.filled", "Appearance: follow macOS")
                button("light", "sun.max", "Appearance: light")
                button("dark", "moon", "Appearance: dark")
            }
        }
    }

    private func button(_ value: String, _ symbol: String, _ help: String) -> some View {
        let on = model.settings.appearance == value
        return Button { model.settings.appearance = value } label: {
            Image(systemName: symbol).symbolVariant(on ? .fill : .none)
        }
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

enum CheckStatus { case ok, missing, warning, info }

/// A row of the Build checklist: status icon, title, detail line, an action button; accepts dropped files.
struct CheckRow<Trailing: View>: View {
    let status: CheckStatus
    let title: String
    let detail: String
    var onDrop: ((URL) -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @State private var targeted = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(status == .missing ? Color.red : Color.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: onDrop == nil ? nil : $targeted) { providers in
            guard let onDrop, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { onDrop(url) } }
            }
            return true
        }
    }

    private var icon: String {
        switch status { case .ok: "checkmark.circle.fill"; case .missing: "xmark.circle"; case .warning: "exclamationmark.triangle.fill"; case .info: "info.circle" }
    }
    private var color: Color {
        switch status { case .ok: .green; case .missing: .red; case .warning: .orange; case .info: .secondary }
    }
}

/// The panels' look: a native DisclosureGroup drawn like a System Settings box (header row with the chevron on the
/// right, the whole row clickable, the content under a divider).
struct GroupedDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { configuration.isExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                Divider()
                configuration.content
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension View {
    /// The same box as the collapsible panels (GroupedDisclosureStyle), for content that is always shown.
    func groupedBox() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A collapsible log panel with Copy, Clear and Save…. Clear empties the on-screen view only; the log file is kept.
struct LogPanel: View {
    let name: String
    let lines: [String]
    @Binding var expanded: Bool
    var height: CGFloat = 200
    var onClear: (() -> Void)? = nil
    var saveName = "MP4 log.txt"

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    }
                    .disabled(lines.isEmpty)
                    if let onClear { Button("Clear", action: onClear).disabled(lines.isEmpty) }
                    Button("Save…") { save() }.disabled(lines.isEmpty)
                }
                .controlSize(.small)
                ScrollViewReader { proxy in
                    // Vertical only, long lines wrapped (user, 2026-11-09): scrolling both ways let the view follow a 400-character line sideways, so the
                    // text started a third of the way in and was cut on the right
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if lines.isEmpty {
                                Text("Nothing logged yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ForEach(Array(lines.suffix(2000).enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading).id(i)
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.visible)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: lines.count) { _, _ in proxy.scrollTo(min(lines.count, 2000) - 1, anchor: .bottom) }
                    .onAppear { proxy.scrollTo(min(lines.count, 2000) - 1, anchor: .bottom) }
                }
            }
        } label: {
            HStack {
                Text(name).fontWeight(.medium)
                Spacer()
                Text(lines.isEmpty ? "empty" : "\(lines.count) line\(lines.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
        }
        .disclosureGroupStyle(GroupedDisclosureStyle())
        .help(expanded ? "Hide the \(name.lowercased())" : "Show the \(name.lowercased())")
    }

    private func save() {
        let p = NSSavePanel()
        p.nameFieldStringValue = saveName
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

enum Panels {
    /// Choose one file (or a folder when `folders`), starting in the user's home.
    @MainActor static func choose(_ title: String, types: [String] = [], folders: Bool = false) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.canChooseFiles = !folders || !types.isEmpty
        p.canChooseDirectories = folders
        p.allowsMultipleSelection = false
        if !types.isEmpty { p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) } }
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor static func confirm(_ title: String, _ text: String, ok: String, destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
        if destructive { a.buttons.first?.hasDestructiveAction = true }
        return a.runModal() == .alertFirstButtonReturn
    }
}

extension Int64 {
    var bytesText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Shortens a path for display: "~/…" and the last two components when it is long.
func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    let parts = p.split(separator: "/")
    return parts.count > 4 ? "…/" + parts.suffix(3).joined(separator: "/") : p
}
