import SwiftUI
import AppKit

/// Game menu > Build for iPad / iPhone…: a window of its own beside the Build window (which stays as it is, user 2026-11-12). It makes an unsigned IPA and
/// the game file in a folder from the finished Mac build; signing, installing and copying the file to the device are the player's. Experimental.
struct IOSBuildWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false
    @State private var destination: URL?

    var body: some View {
        let s = model.settings, b = model.iosBuild
        let dest = destination ?? IOSBuildController.defaultDestination(s)
        let macReady = s.gameReady && !s.buildPartial
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Build for iPad / iPhone").font(.title2.bold())
                Text("Experimental").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2), in: Capsule())
            }
            Text("Makes an unsigned app (IPA) and the game file (RomFS.img, about 28 GB) in a folder, from your finished Mac build. Signing and installing the app (AltStore, SideStore, Sideloadly, LiveContainer or your own Xcode) and copying the game file to the device are up to you; the folder has a short READ ME.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                row(macReady, "A finished Mac build", macReady ? "The iPad build uses its game files and shader tables; it does not change it." : "Build the game for the Mac first (Build window) and let it finish.")
                row(nil, "Xcode with the iOS platform", "Xcode > Settings > Components: iOS and the Metal Toolchain. Checked when the build starts.")
                row(nil, "A device with M1 / A17 Pro or later, 8 GB", "Tested on an iPad Air M2 (8 GB): 60 fps in the first areas. iPhones are untested.")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).groupedBox()

            Text("Only the shaders of the recorded playthroughs go in (about 6,400; a few minutes). Areas past them may draw incomplete or stutter.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Output folder").font(.callout)
                Text(dest.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary).help(dest.path)
                Spacer()
                Button("Choose…") { choose() }.disabled(b.isRunning)
            }

            switch b.state {
            case .idle:
                EmptyView()
            case .running, .cancelling:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(b.percent), total: 100)
                    Text(b.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            case .done:
                Label("Done. The IPA, the game file and the READ ME are in the output folder.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .cancelled:
                Label("Stopped.", systemImage: "stop.circle").foregroundStyle(.secondary)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if b.state == .done, let r = b.resultURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r]) }
                }
                Spacer()
                if b.isRunning {
                    Button("Stop", role: .cancel) { b.cancel() }.disabled(b.state == .cancelling)
                } else {
                    Button(b.state == .idle ? "Build" : "Build again") { b.start(settings: s, destination: dest) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!macReady || model.build.isRunning || model.play.isRunning)
                        .help(model.play.isRunning ? "Close the game first." : model.build.isRunning ? "Wait for the Mac build to finish." : "")
                }
            }

            LogPanel(name: "Details", lines: b.log.lines, expanded: $showLog, height: 200, onClear: { b.log.clear() }, saveName: "MP4 iPad build log.txt")
        }
        .padding(20)
        .frame(width: 640)
    }

    @ViewBuilder private func row(_ ok: Bool?, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok == nil ? "info.circle" : ok! ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok == nil ? Color.secondary : ok! ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.message = "The folder for the IPA and the game file. On the build's drive the 28 GB game file is linked, not copied."
        if p.runModal() == .OK, let u = p.url { destination = u }
    }
}
