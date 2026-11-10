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

    /// Tools change only with a new version of the app (tested as a pair): when this app's tools differ from the ones
    /// in the game folder, they are installed at once (a few seconds; game data, saves and shaders untouched).
    /// The manual "Update tools" button exists only in builds made with TOOLS_UPDATE_BUTTON=1.
    func installToolsIfNeeded() {
        settings.cleanLeftoverRemovals()   // what an interrupted safe removal left (AppSettings.removeSafely)
        #if !TOOLS_UPDATE_BUTTON
        guard settings.toolsOutdated, !play.isRunning, !build.isRunning else { return }
        build.start(settings: settings, mode: .updateTools)
        #endif
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
