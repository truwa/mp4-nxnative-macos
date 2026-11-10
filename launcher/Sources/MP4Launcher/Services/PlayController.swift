import Foundation
import Observation

/// Launches the game binary, captures stderr to a log file and tracks the exit code.
@Observable @MainActor
final class PlayController {
    enum State: Equatable {
        case idle, running
        case exited(Int32)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var logFileURL: URL?
    private(set) var startedAt: Date?
    /// "2560x1440": the render size the game program logs ("render size WxH", the scene's depth target), the last one seen in this run
    private(set) var renderSize: String?
    let log = LogStore(limit: 2000)
    private var runner: ProcessRunner?
    private var logHandle: FileHandle?

    var isRunning: Bool { state == .running }
    /// Called after the game starts or ends (AppModel: the build's priority follows the game)
    var onStateChange: (() -> Void)?
    private var stoppedByUser = false
    /// The last run ended by itself with an error (not the player's Stop or a normal quit).
    var endedUnexpectedly: Bool {
        switch state {
        case .exited(let c): return c != 0 && !stoppedByUser
        case .failed: return true
        default: return false
        }
    }

    func launch(settings: AppSettings) {
        renderSize = nil
        guard !isRunning else { return }
        let binary = settings.gameBinaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            state = .failed("The game program is missing (\(binary.path)). Build the game first."); return
        }
        guard settings.gameReady else {
            state = .failed("The game isn't built yet. Build it first."); return
        }
        log.clear()
        stoppedByUser = false
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: settings.logsURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: settings.userDataURL, withIntermediateDirectories: true)
        } catch {
            state = .failed("Cannot create folders in \(settings.cacheURL.path): \(error.localizedDescription)"); return
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = settings.logsURL.appendingPathComponent(f.string(from: Date()) + ".log")
        fm.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        logFileURL = url
        settings.pruneLogs(build: false)   // the newest 20 play logs stay

        // nx_play.py refreshes the resolution table from the installed packs, then becomes the game (exec): same process.
        let exe = settings.pythonURL
        if settings.resolution != "native" && settings.activeResolution == nil {
            log.append("Resolution \(settings.resolution) is not one this version offers; playing at 900p (1600x900)")
        }
        if let note = settings.backupSavesBeforePlay() { log.append(note) }
        // The game runs from inside "MP4 Game.app" so macOS sees a game (Game Mode, the games category); without the bundle it was a bare program and
        // Game Mode never engaged (2026-11-10). If the bundle cannot be made, the game still starts, from build.noindex/tools/dmhost
        var args = ["-E", "-s", "-B", settings.playScriptURL.path] + settings.playArguments
        do { args += ["--exe", try Self.makeGameApp(settings: settings).path] }
        catch { log.append("[RED] The game's app bundle could not be made (\(error.localizedDescription)): playing without Game Mode") }
        let header = "$ nx_play.py \(settings.playArguments.joined(separator: " "))"
        log.append(header)
        for (k, v) in settings.gameEnvironmentSummary { log.append("  \(k)=\(v)") }

        let r = ProcessRunner(executable: exe, arguments: args,
                              workingDirectory: settings.runtimeURL, environment: settings.gameEnvironment)
        r.onStderrLine = { [weak self] in self?.record($0) }
        r.onStdoutLine = { [weak self] in self?.record($0) }
        r.onExit = { [weak self] code in
            guard let self else { return }
            self.runner = nil
            self.record("--- exited with code \(code) ---")
            try? self.logHandle?.close(); self.logHandle = nil
            self.state = .exited(code)
            self.onStateChange?()
        }
        runner = r
        startedAt = Date()
        do { try r.start(); state = .running } catch {
            state = .failed("Could not launch: \(error.localizedDescription)")
        }
        onStateChange?()
    }

    func stop() { stoppedByUser = true; runner?.cancel(grace: 5) }

    /// `<game folder>/build.noindex/MP4 Game.app`: an app bundle around the game program, so macOS sees a game (games category, Game Mode in full screen).
    /// Its executable is a hard link to build.noindex/tools/dmhost (same drive: no extra space; a copy where a link is refused), made again on every launch,
    /// so a rebuilt game program is picked up. nx_play.py execs it (--exe). Nothing else in the game folder is touched.
    static func makeGameApp(settings: AppSettings) throws -> URL {
        let fm = FileManager.default
        let app = settings.gameAppURL, macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        if fm.fileExists(atPath: settings.oldGameAppURL.path) {   // an earlier version's bundle in the game folder, where players could see it
            try? fm.removeItem(at: settings.oldGameAppURL)   // Launch Services drops an app whose bundle is gone
        }
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleExecutable": "mp4-native",
            "CFBundleIdentifier": "local.mp4nxnative.game",
            "CFBundleName": "MP4",
            "CFBundleIconFile": "AppIcon",
            "CFBundleDisplayName": settings.game.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "26.0",
            "LSApplicationCategoryType": "public.app-category.action-games",
            // macOS Game Mode (the Play screen's Game Mode switch, user 2026-11-10): the game gets CPU and GPU priority and lower Bluetooth latency for controllers
            // while it is fullscreen; off: the game opts out. Read when the game starts (this bundle is made again on every launch and registered below)
            "LSSupportsGameMode": settings.gameMode,
            "GCSupportsGameMode": settings.gameMode,
            "NSHighResolutionCapable": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {   // the launcher's icon for the game too
            let res = app.appendingPathComponent("Contents/Resources", isDirectory: true)
            try? fm.createDirectory(at: res, withIntermediateDirectories: true)
            let dst = res.appendingPathComponent("AppIcon.icns")
            try? fm.removeItem(at: dst); try? fm.copyItem(at: icon, to: dst)
        }
        let exe = settings.gameAppExecutableURL
        if (try? fm.destinationOfSymbolicLink(atPath: exe.path)) != nil || fm.fileExists(atPath: exe.path) {
            try fm.removeItem(at: exe)
        }
        do { try fm.linkItem(at: settings.gameBinaryURL, to: exe) } catch { try fm.copyItem(at: settings.gameBinaryURL, to: exe) }
        LSRegisterURL(app as CFURL, true)   // Launch Services reads the changed Info.plist (Game Mode on / off) now, not a cached copy
        return exe
    }

    private func record(_ line: String) {
        log.append(line)
        if let r = line.range(of: #"render size [0-9]+x[0-9]+"#, options: .regularExpression) { renderSize = String(line[r].dropFirst(12)) }
        if let d = (line + "\n").data(using: .utf8) { logHandle?.write(d) }
    }
}
