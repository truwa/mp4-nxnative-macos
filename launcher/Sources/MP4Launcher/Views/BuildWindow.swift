import SwiftUI
import AppKit

/// The Build window: a checklist of what the build needs, then the build itself in the same window.
struct BuildWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch model.build.state {
            case .idle, .cancelled: Checklist()
            default: BuildProgress(openPlay: openPlay)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 540)
        .navigationTitle("MP4 nxnative – Build the game")
        .background(CloseGuard(model: model))
        .onAppear {
            // No build in the game folder: Quick start is selected, whatever was stored (user, 2026-11-09): it changes only the order of the work, not what
            // the build makes. The player may still turn it off for this build; an unfinished build keeps its own choice.
            let s = model.settings
            if !s.gameReady && !s.buildUnfinished && !s.quickStart { s.quickStart = true }
            model.installToolsIfNeeded()   // a found build without ready.json, an older game program
            // Closing this window goes back to the Play window when a build is playable (QuitGuard.backToPlay), instead of quitting the launcher
            QuitGuard.backToPlay = { [openWindow] in
                guard model.settings.gameReady else { return false }
                openWindow(id: "play"); return true
            }
        }
        .onChange(of: model.settings.cacheURL) { model.installToolsIfNeeded() }   // another build folder: its own state
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // ⌘W / File > Close skip the close button's guard: the same way back to Play when this is the last launcher window
            guard let w = note.object as? NSWindow, w.title == QuitGuard.buildTitle, !QuitGuard.quitting else { return }
            let others = NSApp.windows.contains { $0 !== w && $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            if !others { _ = QuitGuard.backToPlay?() }
        }
    }

    private func openPlay() {
        openWindow(id: "play")
        dismissWindow(id: "build")
    }
}

// MARK: Checklist

private struct Checklist: View {
    @Environment(AppModel.self) private var model
    @State private var baseError: String?
    @State private var updateError: String?
    @State private var keysError: String?
    @State private var detected: RyujinxFinder.Result?
    @State private var askMode = false
    @State private var askStartOver = false
    @State private var askNoChangeRebuild = false
    /// A fresh build: what to expect, once, before it starts (the build estimates its own time in its first minutes)
    @State private var showInfo = false
    @State private var noindexChoice: (plain: URL, noindex: URL)?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private func openPlay() { openWindow(id: "play"); dismissWindow(id: "build") }

    private var s: AppSettings { model.settings }
    private var titleID: String { s.game.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Build the game").font(.title2.weight(.semibold))
                Text("Drop a file (or the folder it's in) on a row, or choose it. Your files are only read.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if s.buildUnfinished { continueBox }   // an unfinished build: Continue first, the checklist below
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("GAME FILES & TOOLS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text("Have Ryujinx or Astris?").font(.caption).foregroundStyle(.secondary)
                    Button("Fill these in from it…") { detected = RyujinxFinder.find(titleID: titleID) }
                        .buttonStyle(.link).font(.caption)
                        .help("Finds the game, the update and prod.keys in your Ryujinx or Astris setup")
                    Text("Only reads files; you confirm first.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                baseRow; Divider()
                updateRow; Divider()
                keysRow; Divider()
                folderRow; Divider()
                metalRow; Divider()
                macRow
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

            optionsBox

            if s.oldLayoutBuild { oldLayoutBanner }
            if s.rebuildRecommended { rebuildBanner }
            if let t = model.foundBuildText { foundBanner(t) }
            if let note = existingNote {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            }
            .padding(.bottom, 4)
            }   // ScrollView: the window may be smaller than the checklist; the buttons below stay in view
            HStack {
                Button("Build speed test…") { openWindow(id: "speedtest") }
                    .help("Compiles a sample of the shaders and estimates the full build's time on this Mac")
                Text(blocker ?? statusText).font(.callout).foregroundStyle(blocker == nil ? Color.secondary : Color.red)
                    .padding(.leading, 6)
                Spacer()
                if s.buildUnfinished {   // an unfinished build can start over (user, 2026-11-09): game data and code again; keys, saves and the compile cache stay
                    Button("Start over…") { askStartOver = true }.disabled(blocker != nil)
                }
                if builtAndPlayable {   // a finished build: Play is the default (blue) button; a rebuild is there, but says it is not needed (user, 2026-11-11)
                    if !s.rebuildRecommended { Button("Rebuild (not needed)…") { askNoChangeRebuild = true }.controlSize(.large).disabled(blocker != nil) }
                    Button("Play") { openPlay() }.keyboardShortcut(.defaultAction).controlSize(.large)
                } else if s.buildPartial {   // playable: Play now is the default (blue) button, Continue building the plain one (user, 2026-11-09)
                    Button("Play now") { openPlay() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    Button("Continue building") { start() }.controlSize(.large).disabled(blocker != nil)
                } else {
                    Button(s.buildUnfinished ? "Continue building" : "Start building") { start() }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .disabled(blocker != nil)
                }
            }
        }
        .sheet(item: Binding(get: { detected.map(DetectBox.init) }, set: { detected = $0?.result })) { box in
            DetectSheet(result: box.result, use: use(_:))
        }
        .confirmationDialog("Keep Spotlight out of the build folder?", isPresented: Binding(get: { noindexChoice != nil }, set: { if !$0 { noindexChoice = nil } })) {
            if let c = noindexChoice {
                Button("Use \(c.noindex.lastPathComponent) (recommended)") { s.changeRoot(to: c.noindex); noindexChoice = nil }
                Button("Use \(c.plain.lastPathComponent)") { s.changeRoot(to: c.plain); noindexChoice = nil }
                Button("Cancel", role: .cancel) { noindexChoice = nil }
            }
        } message: {
            Text("A folder whose name ends in .noindex is skipped by Spotlight, which otherwise indexes the build's files while it runs and slows the build down. Nothing else changes.")
        }
        .alert("Building takes a while", isPresented: $showInfo) {
            Button("Start building") { model.build.start(settings: s, mode: .continueBuild) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("About 260,000 shaders are compiled for your Mac. This takes a few hours (about 2 h 40 min on a Mac mini M4). A time estimate appears in about 3 minutes." + (s.quickStart ? "\n\nWith Quick start you can play after about 10 minutes while the rest compiles." : "\n\nTurn on Quick start to play after about 10 minutes while the rest compiles."))
        }
        .alert("Rebuild with nothing changed?", isPresented: $askNoChangeRebuild) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild", role: .destructive) { model.build.start(settings: s, mode: .fromScratch) }
        } message: {
            Text("This build is up to date: this version of the app would make the same game. A rebuild makes the game data and code again"
                 + ((s.readyInfo?["storage"] as? String ?? s.storage) == "minimal"
                    ? " and compiles every shader again (this build kept no compile cache): about as long as the first build (about 2 h 40 min on a Mac mini M4)."
                    : "; the shaders come back from this build's compile cache, which is much faster than the first build.")
                 + " Your saves and keys are kept. Only useful when the game misbehaves and you want to rule out a damaged build.")
        }
        .confirmationDialog("Start this build over?", isPresented: $askStartOver) {
            Button("Start over", role: .destructive) { model.build.start(settings: s, mode: .fromScratch) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The game data and the game program are made again from your dumps. Your saves, keys and the shaders compiled so far are kept, so the shaders go faster the second time.")
        }
        .confirmationDialog("This folder already has a build", isPresented: $askMode) {
            if s.rebuildRecommended {
                Button(s.rebuildRequired ? "Rebuild (required)" : "Rebuild (recommended)") { model.build.start(settings: s, mode: .rebuild) }
            }
            #if TOOLS_UPDATE_BUTTON
            Button("Update tools") { model.build.start(settings: s, mode: .updateTools) }
            #endif
            Button("Build again", role: .destructive) { model.build.start(settings: s, mode: .fromScratch) }
            Button("Cancel", role: .cancel) {}
        } message: {
            #if TOOLS_UPDATE_BUTTON
            Text("Update tools takes a few seconds. Build from scratch merges the game data again (several minutes). Your saves, keys and prepared shaders are kept either way.")
            #else
            Text("Building again redoes only what changed: every step whose inputs are the same is reused, and finished shaders are kept. Your saves and keys stay.")
            #endif
        }
    }

    /// The chosen folder gets an mp4nxnative folder inside (unless it is one). Outside a .noindex folder the player is offered mp4nxnative.noindex,
    /// which Spotlight skips; a folder that already holds a build is used as it is.
    private func chooseRoot(_ u: URL) {
        let fm = FileManager.default
        if ["mp4nxnative", "mp4nxnative.noindex"].contains(u.lastPathComponent) { s.changeRoot(to: u); return }
        let plain = u.appendingPathComponent("mp4nxnative", isDirectory: true), noindex = u.appendingPathComponent("mp4nxnative.noindex", isDirectory: true)
        if u.pathComponents.contains(where: { $0.hasSuffix(".noindex") }) { s.changeRoot(to: fm.fileExists(atPath: noindex.path) ? noindex : plain); return }
        if fm.fileExists(atPath: noindex.path) { s.changeRoot(to: noindex); return }
        if fm.fileExists(atPath: plain.appendingPathComponent(s.game.id).path) { s.changeRoot(to: plain); return }   // an existing build stays where it is
        noindexChoice = (plain, noindex)
    }

    /// An unfinished build: how far it got, whether the game can be played meanwhile, and Continue (the button row below)
    private var continueBox: some View {
        let count = s.shadersDone
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Build paused").font(.headline)
                    Spacer()
                    Text(count.map { "\($0.done.formatted()) of \($0.total.formatted()) shaders done" } ?? "").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(s.buildPartial
                     ? "You can play with what's finished. Continue building compiles the rest in the background and keeps everything already done."
                     : "Continue building goes on where it stopped and keeps everything already done.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Options

    @ViewBuilder private var optionsBox: some View {
        @Bindable var s = s
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").frame(width: 90, alignment: .leading)
                Picker("", selection: $s.storage) {
                    ForEach(["minimal", "normal", "full"], id: \.self) { k in
                        let e = AppSettings.storageEstimates[k]!
                        Text(k == "full" ? "Troubleshooting · ~\(e.finished) GB" : "\(k.capitalized) · ~\(e.finished) GB").tag(k)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().disabled(s.testBuild)
            }
            Text(s.testBuild ? "Test build: about \(AppSettings.testBuildEstimate) GB." : (AppSettings.storageText[s.storage] ?? "")
                 + " Needs about \(AppSettings.storageEstimates[s.storage]!.building) GB free while building, \(AppSettings.storageEstimates[s.storage]!.finished) GB when finished (estimates).")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 98)
            Toggle(isOn: $s.quickStart) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quick start (experimental)")
                    Text("Compiles the shaders of the start of the game first: play after about 10 minutes while the rest compile at low priority. Past the Carvex fight, areas may draw incomplete until the build gets there.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(s.testBuild)
            if s.testBuild {   // switched in the Game menu (Test Build); shown here so the other folder is never a surprise
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Test build").font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                    Text("Only the recorded shaders, in \(s.game.id)-test beside the real build. Turn it off in Game > Test Build.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    // MARK: Rows

    private var needsDumps: Bool { !s.stepDone("code") || !s.stepDone("romfs") }

    private var baseRow: some View {
        let (st, detail) = check(path: s.basePath, want: .base, error: baseError,
                                 empty: "Not chosen. Drop your .xci or .nsp here")
        return CheckRow(status: needsDumps ? st : (st == .ok ? .ok : .info), title: "Base game",
                        detail: needsDumps ? detail : (st == .ok ? detail : "Not needed: the game data is already built"),
                        onDrop: { take($0, as: .base) }) {
            Button("Choose…") { if let u = Panels.choose("Choose the base game", types: ["xci", "nsp"]) { take(u, as: .base) } }
        }
    }

    private var updateRow: some View {
        let (st, detail) = check(path: s.updatePath, want: .update, error: updateError,
                                 empty: "Not chosen. Drop the 1.1.0 update (.nsp) here")
        return CheckRow(status: needsDumps ? st : (st == .ok ? .ok : .info), title: "1.1.0 update",
                        detail: needsDumps ? detail : (st == .ok ? detail : "Not needed: the game data is already built"),
                        onDrop: { take($0, as: .update) }) {
            Button("Choose…") { if let u = Panels.choose("Choose the 1.1.0 update", types: ["nsp"]) { take(u, as: .update) } }
        }
    }

    private var keysRow: some View {
        let ok = s.keysPresent
        let detail = keysError ?? (ok ? "Stored in the build folder" : "Not chosen. Drop your console's prod.keys here")
        return CheckRow(status: ok && keysError == nil ? .ok : (needsDumps ? .missing : .info), title: "prod.keys",
                        detail: !ok && !needsDumps && keysError == nil ? "Not needed: the game data is already built" : detail,
                        onDrop: { takeKeys($0) }) {
            Button(ok ? "Replace…" : "Choose…") { if let u = Panels.choose("Choose prod.keys", types: ["keys"]) { takeKeys(u) } }
        }
    }

    private var folderRow: some View {
        let free = s.freeBytes, need = s.neededBytes
        let enough = (free ?? Int64.max) >= need
        let detail = "\(displayPath(s.rootURL.path)) · " + (free.map { "\($0.bytesText) free" } ?? "free space unknown")
            + ", about \(need.bytesText) needed"
        return CheckRow(status: enough ? .ok : .missing, title: "Build folder", detail: detail) {
            Button("Change…") {
                if let u = Panels.choose("Choose the build folder", folders: true) { chooseRoot(u) }
            }
            .disabled(model.play.isRunning)
        }
    }

    private var macRow: some View {
        let ok = MacInfo.isAppleSilicon && MacInfo.macOSSupported
        let lowMemory = MacInfo.memoryGB < 16
        let detail = "\(MacInfo.chip), \(MacInfo.memoryGB) GB, macOS \(MacInfo.macOS) · built-in tools \(s.pythonPresent ? "ready" : "missing")"
            + (lowMemory ? " · 16 GB recommended" : "")
        return CheckRow(status: !ok || !s.pythonPresent ? .missing : (lowMemory ? .warning : .ok), title: "This Mac", detail: detail) { EmptyView() }
    }

    private var metalRow: some View {
        let m = MetalToolchain.shared
        let st: CheckStatus = !m.checked || m.downloading ? .info : m.version == nil ? .missing : (m.matchesTested ? .ok : .warning)
        return CheckRow(status: st, title: "Xcode and Metal", detail: m.detail) {
            if m.checked && !m.downloading {
                switch m.problem {
                case .noXcode: Button("Get Xcode…") { NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/xcode/id497799835")!) }
                case .noToolchain: Button("Download Metal Toolchain") { Task { await m.download() } }
                default: EmptyView()
                }
                if m.version == nil { Button("Check again") { Task { await m.check(force: true) } } }
            } else if m.downloading { ProgressView().controlSize(.small) }
        }
        .task { await m.check() }
    }

    /// Status and text for a dump row: the file must exist and be the right kind (an NSP by its ticket, an XCI by name).
    private func check(path: String, want: RyujinxFinder.Kind, error: String?, empty: String) -> (CheckStatus, String) {
        if let error { return (.missing, error) }
        guard !path.isEmpty else { return (.missing, empty) }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return (.missing, "\(displayPath(path)) is no longer there (moved, or its drive is not connected)") }
        let kind = RyujinxFinder.classify(url, titleID: titleID)
        if kind == want { return (.ok, displayPath(path) + (want == .update ? " · version 1.1.0 update" : " · Metroid Prime 4")) }
        if kind == nil && url.pathExtension.lowercased() == "xci" { return (.warning, displayPath(path) + " · can't tell from the name; the build checks it") }
        return (.missing, displayPath(path) + (kind == .base ? " is the base game, not the update" : kind == .update ? " is the update, not the base game" : " isn't Metroid Prime 4's " + (want == .base ? "base game" : "update")))
    }

    // MARK: Taking files

    private func take(_ url: URL, as want: RyujinxFinder.Kind) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let found = RyujinxFinder.search(url, titleID: titleID)
            if let b = found.base { s.basePath = b.path; baseError = nil }
            if let u = found.update { s.updatePath = u.path; updateError = nil }
            if s.keysPresent == false, let k = found.keys { takeKeys(k) }
            if (want == .base ? found.base : found.update) == nil {
                setError(want, "No \(want == .base ? "base game" : "1.1.0 update") found in \(displayPath(url.path))")
            }
            return
        }
        guard ["xci", "nsp"].contains(url.pathExtension.lowercased()) else { setError(want, "Choose an .xci or .nsp file"); return }
        if want == .base { s.basePath = url.path; baseError = nil } else { s.updatePath = url.path; updateError = nil }
    }

    private func setError(_ want: RyujinxFinder.Kind, _ m: String) { if want == .base { baseError = m } else { updateError = m } }

    private func takeKeys(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let file = isDir.boolValue ? RyujinxFinder.search(url, titleID: titleID).keys : url
        guard let file else { keysError = "No prod.keys found in \(displayPath(url.path))"; return }
        do { try s.setKeys(from: file); keysError = nil } catch { keysError = error.localizedDescription }
    }

    private func use(_ r: RyujinxFinder.Result) {
        if let b = r.base { s.basePath = b; baseError = nil }
        if let u = r.update { s.updatePath = u; updateError = nil }
        if let k = r.keys { takeKeys(URL(fileURLWithPath: k)) }
        if !r.packs.isEmpty { _ = try? ResolutionPacks.copy(r.packs, into: s.modsDirURL); s.packsChanged() }
        detected = nil
    }

    /// A build from before the packs in this folder: up to millions of small files. Removed the safe way (AppSettings.removeSafely), never through Finder
    private var oldLayoutBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("An old-layout build is in this folder").font(.headline)
                Text("It holds up to millions of small files. Don't copy, move or delete it in Finder: that can hang Finder and damage the drive. Remove it here instead: it is moved aside at once and deleted in the background. Your saves and keys stay.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Remove it") {
                guard Panels.confirm("Remove the old build?", "The old game data and shaders are deleted in the background; this cannot be undone. Your saves and keys are kept.", ok: "Remove", destructive: true) else { return }
                s.removeSafely([s.workURL, s.readyURL, s.stampsURL])
            }
            .controlSize(.large).disabled(model.play.isRunning || model.build.isRunning)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    /// "Rebuild recommended / required": what changed, how long, what is kept, and the button for just those steps.
    private var rebuildBanner: some View {
        let f = s.runtimeBuildFormat
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.rebuildRequired ? "exclamationmark.triangle.fill" : "sparkles")
                .foregroundStyle(s.rebuildRequired ? Color.orange : Color.accentColor).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.rebuildRequired ? "Rebuild required" : "Rebuild recommended").font(.headline)
                Text((s.rebuildNote.isEmpty ? "This version of the app builds the game data in an improved way." : s.rebuildNote)
                     + (f.estimate.isEmpty ? "" : " Takes \(f.estimate).")
                     + " Your saves, keys and prepared shaders are kept.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Rebuild") { model.build.start(settings: s, mode: .rebuild) }
                .controlSize(.large).disabled(model.play.isRunning)
        }
        .padding(12)
        .background((s.rebuildRequired ? Color.orange : Color.accentColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Start

    private var existingNote: String? {
        if s.gameReady && !s.buildUnfinished && s.rebuildRequired {
            return "This folder already has a build (1.1.0, built \(shortDate(s.builtDate)), runtime \(s.builtRuntimeVersion ?? "?")). Building again keeps your saves and prepared shaders; you'll be asked first."
        }
        return nil   // a playable finished build: the status line says it; an unfinished one: continueBox says it
    }

    /// A finished build this app can play (an up-to-date one, or one whose rebuild is only recommended).
    private var builtAndPlayable: Bool { s.gameReady && !s.buildUnfinished && !s.rebuildRequired }

    private var statusText: String {
        if builtAndPlayable { return "Built 1.1.0 on \(shortDate(s.builtDate))" + (s.rebuildRecommended ? " · a rebuild is recommended" : " · up to date") }
        return s.buildUnfinished ? "Ready to continue" : "Ready to build"
    }

    /// A build found in the folder without its ready.json (nx_build.py --check-ready): "Use it" writes the record, nothing is built.
    private func foundBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("A playable build is in this folder").font(.headline)
                Text(text + " Use it to play it as it is: nothing is built again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Use it") { model.useFoundBuild() }.controlSize(.large).disabled(model.build.isRunning)
        }
        .padding(12)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var blocker: String? {
        if model.play.isRunning { return "Quit the game to build" }
        if !(MacInfo.isAppleSilicon && MacInfo.macOSSupported) { return "Needs an Apple silicon Mac with macOS 26 or later" }
        if !s.pythonPresent { return "The app's built-in tools are missing. Download the app again." }
        if (s.freeBytes ?? Int64.max) < s.neededBytes { return "Not enough free space in the build folder" }
        if MetalToolchain.shared.checked && MetalToolchain.shared.version == nil { return MetalToolchain.shared.problem == .noToolchain ? "Download the Metal Toolchain to continue" : MetalToolchain.shared.problem == .noXcode ? "Install Xcode to continue" : "Fix Xcode's Metal compiler to continue" }
        if needsDumps {
            if baseError != nil || check(path: s.basePath, want: .base, error: nil, empty: "").0 == .missing { return "Choose the base game to continue" }
            if updateError != nil || check(path: s.updatePath, want: .update, error: nil, empty: "").0 == .missing { return "Choose the 1.1.0 update to continue" }
            if !s.keysPresent { return "Choose prod.keys to continue" }
        }
        return nil
    }

    private func start() {
        if s.gameReady && !s.buildUnfinished { askMode = true; return }
        if s.buildUnfinished || s.testBuild { model.build.start(settings: s, mode: .continueBuild); return }   // an unfinished build continues, no question: its own rate gives the time
        showInfo = true   // a fresh build: what to expect, then it starts
    }

    private func shortDate(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso + "Z") ?? DateFormatter.isoLocal.date(from: iso) else { return iso ?? "?" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

private extension DateFormatter {
    static let isoLocal: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }()
}

private struct DetectBox: Identifiable {
    let result: RyujinxFinder.Result
    var id: String { (result.base ?? "") + (result.update ?? "") + (result.keys ?? "") + result.sources.joined() }
}

/// What Detect found; nothing is used until "Use these".
private struct DetectSheet: View {
    let result: RyujinxFinder.Result
    let use: (RyujinxFinder.Result) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Found in your Ryujinx or Astris setup").font(.title3.weight(.semibold))
            if result.sources.isEmpty {
                Text("No Ryujinx or Astris setup was found on this Mac.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Base game", result.base)
                    row("1.1.0 update", result.update)
                    row("prod.keys", result.keys, note: "copied into the build folder")
                    // Resolution packs: not shown while mod support is held back (user, 2026-11-09); the sizes come from the game's own code
                }
                Text("Looked in: \(result.sources.joined(separator: ", "))" + (result.gameDirs.isEmpty ? " (no game folders set there)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Use these") { use(result) }.keyboardShortcut(.defaultAction).disabled(!result.found)
            }
        }
        .padding(20).frame(width: 560)
    }

    private func row(_ title: String, _ value: String?, note: String? = nil) -> some View {
        GridRow {
            Image(systemName: value == nil ? "xmark.circle" : "checkmark.circle.fill").foregroundStyle(value == nil ? Color.secondary : Color.green)
            Text(title).font(.body.weight(.medium))
            VStack(alignment: .leading, spacing: 1) {
                Text(value.map(displayPath) ?? "not found").foregroundStyle(value == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                if value != nil, let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: Building

private struct BuildProgress: View {
    @Environment(AppModel.self) private var model
    let openPlay: () -> Void
    @State private var showLog = false
    @State private var handledDone = false

    private var b: BuildController { model.build }

    var body: some View {
        @Bindable var s = model.settings
        return VStack(alignment: .leading, spacing: 16) {
            header
            if b.isRunning || b.state == .done {
                VStack(alignment: .leading, spacing: 6) {
                    // The whole-build line (todo.md, 2026-11-09): one clock, one estimate, counts that only grow, a percentage that never goes back
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        ProgressView(value: b.overall)
                        HStack {
                            Text("Whole build \(Int(b.overall * 100))%").monospacedDigit()
                            Text(b.state == .done ? "· took \(b.elapsedInAll.hmText)"
                                 : "· running \(b.elapsedThisSession.hmText)" + (b.elapsedBefore > 60 ? " (\(b.elapsedInAll.hmText) in all)" : "")).monospacedDigit()
                            Spacer()
                            Text(b.state == .done ? "" : b.state == .paused ? "paused" : b.waiting ? "waiting for the game to close" : (b.etaSeconds?.etaText ?? "estimating time left"))
                        }
                        HStack {
                            Text(wholeCounts).monospacedDigit()
                            Spacer()
                            if b.state != .done {
                                Text("Priority")
                                Picker("", selection: $s.buildPriority) { Text("Normal").tag("normal"); Text("Low").tag("low") }
                                    .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                                    .onChange(of: s.buildPriority) { _, _ in model.updateBuildPriority() }
                                    .help("Low: the Mac stays responsive for other work; the shaders take about a third longer. While the game runs the build is always low. A change restarts the shader step under the new setting within seconds; finished shaders are kept.")
                                if b.gameRunning { Text("· low while you play") }
                            }
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if let e = b.estimateSeconds, b.state != .done {
                        Text("Estimate for this Mac: the whole build takes about \(TimeInterval(e).hmText).").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            steps
            LogPanel(name: "Details", lines: b.log.lines, expanded: $showLog, height: 200,
                     onClear: { b.log.clear() }, saveName: "MP4 build log.txt")
            Spacer(minLength: 0)
            footer
        }
        .onChange(of: b.state) { _, st in
            if case .failed = st { showLog = true }
            if st == .done, !handledDone { handledDone = true; model.buildFinished() }
        }
    }

    @ViewBuilder private var header: some View {
        switch b.state {
        case .done:
            Label("Build complete", systemImage: "checkmark.seal.fill").font(.title2.weight(.semibold)).foregroundStyle(.green)
            Text(b.mode == .updateTools ? "The tools are up to date."
                 : model.settings.testBuild ? "The test build is ready, with the recorded shaders. The time of each step is in the logs folder (build-times.tsv)."
                 : "The game is ready, with every shader compiled. The time of each step is in the logs folder (build-times.tsv).")
                .foregroundStyle(.secondary)
        case .failed(let m):
            Label("The build stopped", systemImage: "exclamationmark.triangle.fill").font(.title2.weight(.semibold)).foregroundStyle(.red)
            Text(m).textSelection(.enabled)
        default:
            if b.estimating && b.state != .cancelling {
                Text("Estimating the build time…").font(.largeTitle.weight(.semibold))
                Text((b.message.isEmpty ? "Preparing the game files" : b.message) + " · about 3 min").foregroundStyle(.secondary)
            } else {
            Text(b.mode == .updateTools ? "Updating the tools" : b.mode == .rebuild ? "Rebuilding" : "Building").font(.title2.weight(.semibold))
            Text(b.message.isEmpty ? BuildController.steps[b.stepIndex].title : b.message).foregroundStyle(.secondary)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(BuildController.steps.enumerated()), id: \.offset) { i, step in
                let done = b.state == .done || i < b.stepIndex
                let current = !done && i == b.stepIndex
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        // While quick start's set compiles, the shader step says so; it goes back to its usual title for the background part (user, 2026-11-09)
                        let title = step.ids.contains("shaders") && b.quickStart && !b.playable ? "Compiling the quick-start shaders" : step.title
                        Text(title).foregroundStyle(current ? .primary : .secondary).fontWeight(current ? .medium : .regular)
                        if !done, let note = stepNote(i, current: current) {
                            if let c = note.count, c.total > 0 {
                                HStack(spacing: 8) {
                                    ProgressView(value: Double(c.done), total: Double(c.total)).frame(maxWidth: 220).controlSize(.small)
                                    Text("\(c.done.formatted()) of \(c.total.formatted())" + (note.text.map { " · \($0)" } ?? "")).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            } else if let t = note.text { Text(t).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } icon: {
                    Image(systemName: done ? "checkmark.circle.fill" : current ? (failed ? "xmark.circle.fill" : "circle.dotted") : "circle")
                        .foregroundStyle(done ? Color.green : current ? (failed ? Color.red : Color.accentColor) : Color.secondary)
                }
            }
        }
    }

    private var failed: Bool { if case .failed = b.state { return true }; return false }

    /// "Shaders 93,072 of 259,989 · Pipelines 2,966 of 129,972": the whole build's counts (COUNT lines), which only grow
    private var wholeCounts: String {
        var parts: [String] = []
        if let c = b.counts["shaders"], c.total > 0 { parts.append("Shaders \(c.done.formatted()) of \(c.total.formatted())") }
        if let c = b.counts["pipelines"], c.total > 0 { parts.append("Pipelines \(c.done.formatted()) of \(c.total.formatted())") }
        return parts.joined(separator: " · ")
    }

    /// A row's own progress (free to say what it is doing: the quick-start set, the sample, the cache check), and what quick start already did for the later steps
    private func stepNote(_ i: Int, current: Bool) -> (count: (done: Int, total: Int)?, text: String?)? {
        let id = BuildController.steps[i].ids
        if id.contains("shaders") {
            if current, b.quickStart, !b.playable, let c = b.counts["part"] { return (c, "the quick-start set first") }
            if let c = b.counts["shaders"], current || c.done > 0 { return (c, nil) }
        }
        if id.contains("pipelines") {
            if current, b.waiting { return (nil, "waiting for the game to close") }
            if current, let c = b.counts["pipelines"] { return (c, nil) }
            if b.playable, !current { return (nil, (b.counts["pipelines"].map { "\($0.done.formatted()) of \($0.total.formatted()) " } ?? "") + "ready for quick start; the rest after the shaders") }
        }
        if b.playable && !current && id.contains("host") { return (nil, "ready for quick start; the rest after the shaders") }
        return nil
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch b.state {
            case .running:
                Text(b.playable ? "The game can be played now; the other shaders compile in the background." : "Stop or quit any time: the next start continues where it stopped.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if b.playable { Button("Play now") { openPlay() }.keyboardShortcut(.defaultAction) }
                Button("Pause") { b.pause() }
                Button("Stop, continue later") { b.cancel() }
            case .paused:
                Text("Paused. Your Mac is free; the build waits.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if b.playable { Button("Play now") { openPlay() }.keyboardShortcut(.defaultAction); Button("Resume") { b.resume() } }
                else { Button("Resume") { b.resume() }.keyboardShortcut(.defaultAction) }
                Button("Stop, continue later") { b.cancel() }
            case .cancelling:
                Spacer()
                Text("Stopping…").foregroundStyle(.secondary)
            case .failed:
                Button("Copy diagnostics") { model.copyDiagnostics() }
                Spacer()
                Button("Back") { b.reset() }
                Button("Try again") { b.start(settings: model.settings, mode: .continueBuild) }.keyboardShortcut(.defaultAction)
            case .done:
                Spacer()
                Button("Open Play") { b.reset(); openPlay() }.keyboardShortcut(.defaultAction).controlSize(.large)
            default:
                EmptyView()
            }
        }
    }
}

/// The Mac's own Metal compiler (Xcode's Metal Toolchain), which compiles the shaders: checked once per launch and on "Check again".
/// xcrun is called only when an Xcode is the selected developer folder: on a Mac with no developer tools /usr/bin/xcrun is a stub that opens macOS's
/// "install the command line tools" offer, which would not help (they have no Metal compiler).
@Observable @MainActor
final class MetalToolchain {
    enum Problem: Equatable { case none, noXcode, notSelected, noToolchain, other(String) }
    static let shared = MetalToolchain()
    static let tested = "32023.922"   // nxnative's dmsh_chain.lock (Xcode 27.2)
    private(set) var checked = false
    private(set) var version: String?
    private(set) var problem: Problem = .none
    private(set) var downloading = false
    private(set) var downloadNote: String?
    var matchesTested: Bool { version?.contains(Self.tested) ?? false }

    var detail: String {
        if downloading { return "Downloading the Metal Toolchain (about 1 GB)…" + (downloadNote.map { " \($0)" } ?? "") }
        if !checked { return "Checking…" }
        if let v = version { return "Metal compiler \(v)" + (matchesTested ? " (the tested one)" : " · untested (the tested one is \(Self.tested)): the shaders may differ") }
        switch problem {
        case .noXcode: return "Xcode is not installed. Install it from the App Store, open it once, then come back."
        case .notSelected: return "Xcode is installed but not selected. In Terminal: sudo xcode-select -s /Applications/Xcode.app"
        case .noToolchain: return "Xcode is installed; its Metal Toolchain is missing." + (downloadNote.map { " \($0)" } ?? "")
        case .other(let e): return "Xcode's Metal compiler does not run: \(e)"
        case .none: return "Not found"
        }
    }

    func check(force: Bool = false) async {
        guard force || !checked else { return }
        let (v, p) = await Task.detached { () -> (String?, Problem) in
            func run(_ exe: String, _ args: [String]) -> (Int32, String, String)? {
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
                guard (try? p.run()) != nil else { return nil }
                let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
            }
            let apps = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []).filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            guard let sel = run("/usr/bin/xcode-select", ["-p"]), sel.0 == 0, sel.1.contains(".app/Contents/Developer") else {
                return (nil, apps.isEmpty ? .noXcode : .notSelected)
            }
            guard let r = run("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"]) else { return (nil, .other("xcrun could not start")) }
            if r.0 == 0 {
                if let m = r.1.range(of: #"metal(fe)? version [0-9.]+"#, options: .regularExpression) {
                    return (String(r.1[m]).replacingOccurrences(of: "metalfe version ", with: "").replacingOccurrences(of: "metal version ", with: ""), .none)
                }
                return (r.1.split(separator: "\n").first.map(String.init) ?? "?", .none)
            }
            let err = (r.2 + r.1).trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("Metal Toolchain") || err.contains("MetalToolchain") { return (nil, .noToolchain) }
            if err.lowercased().contains("license") { return (nil, .other("open Xcode once to accept its licence")) }
            return (nil, .other(err.split(separator: "\n").last.map(String.init) ?? "exit \(r.0)"))
        }.value
        version = v; problem = p; checked = true
    }

    /// xcodebuild -downloadComponent MetalToolchain (no administrator password), then the check again
    func download() async {
        guard !downloading else { return }
        downloading = true; downloadNote = nil
        let (code, last) = await Task.detached { () -> (Int32, String) in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild"); p.arguments = ["-downloadComponent", "MetalToolchain"]
            let o = Pipe(); p.standardOutput = o; p.standardError = o
            guard (try? p.run()) != nil else { return (-1, "xcodebuild could not start") }
            let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (p.terminationStatus, text.split(separator: "\n").last.map(String.init) ?? "")
        }.value
        downloading = false
        await check(force: true)
        if version == nil { downloadNote = code == 0 ? "The download ended but the compiler is still missing: open Xcode > Settings > Components." : "The download failed: \(last)" }
    }
}
