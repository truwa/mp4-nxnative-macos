import SwiftUI
import AppKit

/// The Play window: Play, the three everyday settings in one row, the shader line, one status line, and the log.
struct PlayWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showLog = false

    private var s: AppSettings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Spacer(); playButton; Spacer() }
            VStack(spacing: 0) {
                controlsRow.padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
                Label(model.controllerLine, systemImage: "gamecontroller").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .groupedBox()
            if s.rebuildRecommended, !s.rebuildRequired {   // quiet: the Build window tells what and why
                Button { showBuild() } label: { Label("New build tools are available", systemImage: "sparkles") }
                    .buttonStyle(.link).font(.callout)
                    .help("A rebuild with this version improves the game. Opens the Build window.")
                    .disabled(model.play.isRunning)
            }
            shaderLine
            if let status { statusBox(status) }
            LogPanel(name: "Log", lines: model.play.log.lines, expanded: $showLog, height: 220,
                     onClear: { model.play.log.clear() }, saveName: "MP4 game log.txt")
        }
        .padding(24)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)   // the window follows the content (no empty space; grows with the log)
        .navigationTitle("MP4 nxnative – \(s.game.name)")
        .toolbar {
            AppearanceButtons()
            ToolbarItem(placement: .primaryAction) {
                Button { showBuild() } label: { Image(systemName: "hammer") }
                    .help("Open the Build window")
                    .accessibilityLabel("Open the Build window")
                    .disabled(model.play.isRunning)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape") }.help("Settings").accessibilityLabel("Settings")
            }
        }
        .background(CloseGuard(model: model))
        .onAppear { s.applyAppearance(); model.shaders.refreshReport(settings: s); model.installToolsIfNeeded() }
        .onChange(of: s.cacheURL) { model.installToolsIfNeeded() }   // another build folder: its own state (a found build, an older game program)
        .onChange(of: model.build.state) { _, st in
            if st == .done, model.build.mode == .updateTools { model.build.reset(); model.shaders.refreshReport(settings: s) }
        }
    }

    // MARK: Play

    @ViewBuilder private var playButton: some View {
        if model.play.isRunning {
            VStack(spacing: 6) {
                Label("Running", systemImage: "play.circle.fill").font(.title3).foregroundStyle(.green)
                if let r = model.play.renderSize { Text("Rendering at \(r)").font(.callout).foregroundStyle(.secondary) }   // the game program's "render size" log line
                Button("Stop game") { model.play.stop() }
            }
        } else {
            Button { model.play.launch(settings: s) } label: {
                Label("Play", systemImage: "play.fill").font(.title2.weight(.semibold)).frame(minWidth: 180, minHeight: 34)
            }
            .buttonStyle(.borderedProminent).controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(!s.gameReady || (model.build.isRunning && !model.build.playable) || s.rebuildRequired)
            .help(model.build.isRunning && !model.build.playable ? "A build is running" : model.build.playable && model.build.isRunning ? "Start the game (the other shaders are still compiling: areas past the recording may draw incomplete for a while)" : s.gameReady ? "Start the game" : "Build the game first")
        }
    }

    // MARK: Everyday settings, one row

    /// One row when it fits; with a long size name ("2880p ultrawide") the gaps shrink, then the switches go to a second line. Every part keeps its own
    /// width (fixedSize): the label was the only flexible part and wrapped letter by letter with an ultrawide size (user's screenshot, 2026-11-11)
    private var controlsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 28) { resolutionControl; switches(spacing: 28) }
            HStack(spacing: 14) { resolutionControl; switches(spacing: 14) }
            VStack(spacing: 10) { resolutionControl; switches(spacing: 28) }
        }
        .frame(maxWidth: .infinity)
    }

    private var resolutionControl: some View {
        HStack(spacing: 6) {
            Text("Resolution").fixedSize()
            Menu {
                ForEach(s.resolutionOptions, id: \.size) { o in resolutionItem(o) }   // a fixed list: every size comes from the game's own code (user, 2026-11-09)
            } label: { Text(s.resolutionShort) }
            .fixedSize()
        }
        .fixedSize()
        .help("900p is the game's own size. The other sizes are made from the game's own code, the scan visor included. Applied when the game starts: no rebuild.")
    }

    private func switches(spacing: CGFloat) -> some View {
        @Bindable var b = s
        return HStack(spacing: spacing) {
            Toggle("Game Mode", isOn: $b.gameMode).toggleStyle(.switch).fixedSize()
                .help("macOS Game Mode while the game is fullscreen: CPU and GPU priority for the game, lower latency for Bluetooth controllers. Applied when the game starts.")
            Toggle("Metal HUD", isOn: $b.metalHUD).toggleStyle(.switch).fixedSize()
                .help("Apple's overlay: frame rate, frame time and memory.")
        }
    }

    /// A menu item: a checkmark on the chosen size; the app-built sizes carry a ✦.
    private func resolutionItem(_ o: AppSettings.ResolutionOption) -> some View {
        Button { s.resolution = o.size } label: {
            let text = o.label
            if o.size == (s.activeResolution?.size ?? "native") { Label(text, systemImage: "checkmark") } else { Text(text) }
        }
    }

    // MARK: Shaders

    private var shaderLine: some View { ShaderPanel() }

    // MARK: Status line (one at a time)

    private struct Status {
        let text: String
        let symbol: String
        var buttons: [(String, () -> Void)] = []
        var busy = false
    }

    private var status: Status? {
        if model.build.isRunning, model.build.mode == .updateTools {
            return Status(text: "Updating the game program for this version…", symbol: "arrow.triangle.2.circlepath", busy: true)
        }
        if !s.gameReady {
            if let t = model.foundBuildText { return Status(text: t, symbol: "checkmark.circle", buttons: [("Use it", { model.useFoundBuild() })]) }
            if s.buildUnfinished { return Status(text: "The build wasn't finished", symbol: "exclamationmark.circle", buttons: [("Finish building", showBuild)]) }
            return Status(text: "The game isn't built yet", symbol: "hammer", buttons: [("Build", showBuild)])
        }
        if s.rebuildRequired {
            return Status(text: "This version needs the game rebuilt" + (s.runtimeBuildFormat.estimate.isEmpty ? "" : " (\(s.runtimeBuildFormat.estimate))"),
                          symbol: "hammer", buttons: [("Open Build", showBuild)])
        }
        if model.play.endedUnexpectedly {
            return Status(text: "The game closed unexpectedly", symbol: "exclamationmark.triangle",
                          buttons: [("Show log", { showLog = true }), ("Copy diagnostics", { model.copyDiagnostics() })])
        }
        #if TOOLS_UPDATE_BUTTON
        if s.toolsOutdated, !model.play.isRunning {
            return Status(text: "A new version of the tools is available", symbol: "arrow.down.circle",
                          buttons: [("Update tools", { model.build.start(settings: s, mode: .updateTools) })])
        }
        #endif
        if !model.shaders.isPrepared, !model.shaders.isActive, !ShaderPrepController.enoughDisk(at: s.cacheURL) {
            return Status(text: "Not enough free space to prepare shaders (18 GB needed)", symbol: "externaldrive.badge.exclamationmark",
                          buttons: [("Open build folder", { NSWorkspace.shared.open(s.rootURL) })])
        }
        return nil
    }

    private func statusBox(_ st: Status) -> some View {
        HStack(spacing: 10) {
            if st.busy { ProgressView().controlSize(.small) } else { Image(systemName: st.symbol).foregroundStyle(.orange) }
            Text(st.text)
            Spacer()
            ForEach(Array(st.buttons.enumerated()), id: \.offset) { _, b in Button(b.0, action: b.1) }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func showBuild() {
        openWindow(id: "build")
        dismissWindow(id: "play")
    }
}

// The mod-pack sheet (frame-rate and Level of Detail packs, a drop area) was here until 2026-11-09: mod support is held back for a later release.

/// The shader line follows the build (todo.md, 2026-11-09): a running build's whole-build numbers every 5 s, a paused or stopped build with a way on,
/// the pipelines' wait for the game, and only then "Compiled by the build ✓". Opens the Build window.
struct ShaderPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let s = model.settings, b = model.build
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            HStack(spacing: 8) {
                Text("Shaders").fontWeight(.medium)
                Spacer()
                if b.isRunning, b.mode != .updateTools {
                    if b.state == .paused {
                        Image(systemName: "pause.circle").foregroundStyle(.secondary)
                        Text("Build paused · \(countText(b))").foregroundStyle(.secondary).monospacedDigit()
                        Button("Continue") { b.resume() }.controlSize(.small)
                    } else if b.waiting {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text("Waiting for the game to close to prepare the pipelines").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                        Text((b.playable ? "Compiling in the background · " : "Building the game · ") + countText(b) + (b.etaSeconds.map { " · \($0.etaText)" } ?? ""))
                            .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    Button { openWindow(id: "build") } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Open the Build window").accessibilityLabel("Open the Build window")
                } else if s.buildUnfinished, !b.isRunning {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text("Not finished" + (s.shadersDone.map { " · \($0.done.formatted()) of \($0.total.formatted())" } ?? "")).foregroundStyle(.secondary).monospacedDigit()
                    Button("Continue building") { b.start(settings: s, mode: .continueBuild) }.controlSize(.small).disabled(model.play.isRunning)
                } else {
                    Text(s.gameReady ? "Compiled by the build ✓" : "Compiled when you build the game").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .groupedBox()
    }

    private func countText(_ b: BuildController) -> String {
        guard let c = b.counts["shaders"], c.total > 0 else { return "starting" }
        return "\(c.done.formatted()) of \(c.total.formatted())"
    }
}
