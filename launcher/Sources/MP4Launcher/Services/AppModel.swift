import Foundation
import Observation
import AppKit
import GameController

/// Everything the windows share, as one environment object.
@Observable @MainActor
final class AppModel {
    let settings = AppSettings()
    let build = BuildController()
    let play = PlayController()
    let shaders = ShaderPrepController()
    /// "DualSense Wireless Controller connected", or "No controller, keyboard".
    private(set) var controllerLine = "No controller, keyboard"
    private var observers: [Any] = []

    init() {
        shaders.refreshReport(settings: settings)
        updateController()
        play.onStateChange = { [weak self] in self?.updateBuildPriority() }
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateController() }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppSettings.clearDefaults() }   // AppKit's window frames; nothing stays in Preferences
        })
        AppSettings.clearDefaults()
    }

    /// The build's priority: low while the game runs, otherwise the setting (Settings > Advanced > Build). A running build switches within ~10 s.
    func updateBuildPriority() {
        build.gameRunning = play.isRunning
        let p = play.isRunning ? "low" : settings.buildPriority
        if build.isRunning, build.priority != p { build.applyPriority(p, settings: settings) }
    }

    private func updateController() {
        let names = GCController.controllers().compactMap { $0.vendorName }.filter { !$0.isEmpty }
        controllerLine = names.isEmpty ? "No controller, keyboard" : names.joined(separator: ", ") + " connected"
    }

    /// Tools change only with a new version of the app (tested as a pair): when a finished build's game program was made by another version of the app
    /// (same shader chain), this app's game program is built into it at once (nx_build.py --update-program: about 30 s; game data, saves and shaders untouched).
    /// The manual "Update tools" button exists only in builds made with TOOLS_UPDATE_BUTTON=1.
    func installToolsIfNeeded() {
        settings.cleanLeftoverRemovals()   // what an interrupted safe removal left (AppSettings.removeSafely)
        checkFoundBuild()
        #if !TOOLS_UPDATE_BUTTON
        guard settings.toolsOutdated, !play.isRunning, !build.isRunning, programTried != settings.cacheURL.path else { return }
        programTried = settings.cacheURL.path   // once per folder per session: a failed update is not retried in a loop (its error is in the Build window)
        build.start(settings: settings, mode: .updateTools)
        #endif
    }
    private var programTried: String?

    // MARK: A playable build without ready.json (deleted, or a build that stopped before writing it)

    /// What nx_build.py --check-ready found in a folder with a build but no ready.json: "finished" or "partial" and its line, nil when nothing playable (or not checked).
    private(set) var foundBuild: (state: String, detail: String)?
    private var foundFor: String?
    private var checker: ProcessRunner?

    /// Runs the read-only check (a few seconds) when the folder has build files but no ready.json; once per folder until it changes.
    func checkFoundBuild() {
        let s = settings, path = s.cacheURL.path
        guard !s.gameReady, !build.isRunning, checker == nil, foundFor != path,
              FileManager.default.fileExists(atPath: s.workURL.appendingPathComponent("tools/dmhost").path) else {
            if s.gameReady { foundBuild = nil }
            return
        }
        foundFor = path; foundBuild = nil
        runCheck(write: false) { [weak self] state, detail in
            guard let self, self.settings.cacheURL.path == path else { return }
            self.foundBuild = state.map { ($0, detail) }
        }
    }

    /// "Use it": writes ready.json for the build found (then the game program is brought up to date like any build of an earlier version).
    func useFoundBuild() {
        runCheck(write: true) { [weak self] state, _ in
            guard let self else { return }
            self.foundBuild = nil; self.foundFor = nil
            self.settings.readyChanged()
            if state != nil { self.installToolsIfNeeded() }
        }
    }

    private func runCheck(write: Bool, done: @escaping @MainActor (String?, String) -> Void) {
        let s = settings
        var args = ["-E", "-s", "-B", s.buildScriptURL.path, "--out", s.cacheURL.path, "--runtime", s.runtimeURL.path, "--check-ready"]
        if write { args.append("--write") }
        let r = ProcessRunner(executable: s.pythonURL, arguments: args, workingDirectory: s.runtimeURL, environment: AppSettings.pythonEnvironment())
        var line = ""
        r.onStdoutLine = { if $0.hasPrefix("READY ") { line = String($0.dropFirst(6)) } }
        r.onExit = { [weak self] _ in
            self?.checker = nil
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let state = parts.first.flatMap { $0 == "finished" || $0 == "partial" ? $0 : nil }
            done(state, parts.count > 1 ? parts[1] : "")
        }
        checker = r
        do { try r.start() } catch { checker = nil; done(nil, "") }
    }

    /// The Play and Build windows' line for a found build.
    var foundBuildText: String? {
        guard let f = foundBuild, !settings.gameReady else { return nil }
        return (f.state == "finished" ? "A finished build was found in this folder" : "A playable build was found in this folder (not finished: Continue building does the rest)")
            + " (\(f.detail)), but its record (ready.json) is missing."
    }

    /// After a build: prepare shaders in the background unless the game is running or they are done.
    func buildFinished() {
        shaders.refreshReport(settings: settings)
    }

    /// The text "Copy diagnostics" puts on the clipboard: versions, this Mac, the build state and log tails.
    /// No keys, no file contents; the home folder is shown as ~.
    func diagnostics() -> String {
        let s = settings
        var lines = [
            "MP4 nxnative \(AppSettings.appVersion) · runtime \(s.runtimeVersion ?? "?") · build runtime \(s.builtRuntimeVersion ?? "none")",
            "Mac: \(MacInfo.chip), \(MacInfo.memoryGB) GB, macOS \(MacInfo.macOS)",
            "Build: \(s.gameReady ? "ready (\(s.builtDate ?? "?"))" : s.buildUnfinished ? "unfinished" : "none"); keys \(s.keysPresent ? "stored" : "missing"); packs \(s.installedResolutionMods.count)",
            "Free space: \(ByteCountFormatter.string(fromByteCount: s.freeBytes ?? 0, countStyle: .file))",
            "Settings: resolution \(s.resolution), HUD \(s.metalHUD)",
            "Shaders: \(shaders.playLine)",
        ]
        if !build.log.lines.isEmpty { lines += ["", "--- build log (last 40 lines) ---"] + build.log.tail(40) }
        if !play.log.lines.isEmpty { lines += ["", "--- game log (last 80 lines) ---"] + play.log.tail(80) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return lines.joined(separator: "\n").replacingOccurrences(of: home, with: "~")
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
    }
}
