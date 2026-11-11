import Foundation
import Observation

/// Runs `build_game.py` and turns its PROGRESS / DONE / ERROR lines into steps, a percentage and a time estimate.
/// Every line also goes to `<game folder>/logs/build-<date>.log`.
@Observable @MainActor
final class BuildController {
    enum State: Equatable {
        case idle, running, paused, cancelling, done, cancelled
        case failed(String)
    }
    enum Mode: Equatable { case continueBuild, updateTools, fromScratch, rebuild }

    /// The five steps the player sees, and which script steps belong to each.
    static let steps: [(title: String, ids: Set<String>)] = [
        ("Reading the game files", ["start", "read"]),
        ("Rewriting the code for Apple silicon", ["rewrite"]),
        ("Splitting the shaders", ["split"]),
        ("Compiling the shaders (the long step)", ["shaders"]),
        ("Building the game program", ["host"]),
        ("Preparing the pipelines", ["pipelines", "done"]),
    ]

    private(set) var state: State = .idle
    private(set) var mode: Mode = .continueBuild
    private(set) var stepID = ""
    private(set) var percent = 0
    private(set) var message = ""
    private(set) var startedAt: Date?
    private(set) var logFileURL: URL?
    let log = LogStore()
    private var runner: ProcessRunner?
    private var logHandle: FileHandle?
    private var sawDone = false
    private var sawError: String?
    /// Time the build stood still in this session (Pause, and waiting for the game to close): left out of the time passed
    private var stillSeconds: TimeInterval = 0
    private var stillSince: Date?
    /// The runner waits for the game to close before the pipelines (WAITING 1)
    private(set) var waiting = false
    /// The whole-build percentage never goes back (todo.md rule 4): the highest value shown so far, raised on every ETA line
    private var overallFloor: Double = 0
    /// The build's priority as applied: "normal" or "low" (low while the game runs; AppModel.updateBuildPriority)
    private(set) var priority = "normal"
    /// The game runs (set by AppModel): the build is low while it does
    var gameRunning = false
    /// The quick start's first part is done (PLAYABLE): the game can be played while the rest compiles.
    private(set) var playable = false
    /// The build script's own estimate of the time left of the whole build (ETA line, nx_build.py TimeLeft: every build)
    private var etaOverride: Double?
    /// Seconds this build already ran in earlier sessions (a stopped build continued: ELAPSED_BEFORE), for "in all"
    private(set) var elapsedBefore: Double = 0
    /// The build's own estimate of the whole build (ESTIMATE line: every fresh build times a sample of the shaders first), seconds
    private(set) var estimateSeconds: Int?
    /// The fresh build's first minutes: the game files and a sample of the shaders, which give the estimate (PHASE estimating … PHASE building)
    private(set) var estimating = false
    /// Each long step's own count (COUNT <step> <done> <total>: shaders, pipelines), for the Build window's rows
    private(set) var counts: [String: (done: Int, total: Int)] = [:]
    /// The build was started with quick start (its first part's counts are the quick-start set)
    private(set) var quickStart = false
    /// The whole build's progress as a share of its time: all sessions' time / (that + time left), and never less than it was (a growing estimate
    /// stalls the bar instead of pulling it back). The step percentages misled (after quick start the bar showed 30% with under 2% of the shaders done,
    /// 2026-11-09). Before a time left is known, the script's percentage
    var overall: Double {
        if state == .done { return 1 }
        return max(overallFloor, computedOverall)
    }
    /// The share of time; 0 until the runner's first estimate (the script's step percentages would show a few percent and then fall back when the
    /// time share takes over). The tools update, which has no shaders, keeps the script's percentage
    private var computedOverall: Double {
        if let eta = etaOverride, elapsedInAll > 30 { return min(0.99, elapsedInAll / (elapsedInAll + eta)) }
        return mode == .updateTools ? Double(percent) / 100 : 0
    }
    /// Time passed in this session (paused and waiting time left out), and in all (earlier sessions included)
    var elapsedThisSession: TimeInterval {
        guard let t0 = startedAt else { return 0 }
        return Date().timeIntervalSince(t0) - stillSeconds - (stillSince.map { Date().timeIntervalSince($0) } ?? 0)
    }
    var elapsedInAll: TimeInterval { elapsedBefore + elapsedThisSession }

    var isRunning: Bool { state == .running || state == .cancelling || state == .paused }
    var isPaused: Bool { state == .paused }

    /// Pause / Resume: the whole build (nx_build.py made itself a process group leader) stops where it is.
    func pause() { guard state == .running else { return }; runner?.signalGroup(SIGSTOP); state = .paused; record("--- paused ---"); standStill(true) }
    func resume() { guard state == .paused else { return }; runner?.signalGroup(SIGCONT); state = .running; record("--- resumed ---"); standStill(waiting) }
    private func standStill(_ still: Bool) {
        if still, stillSince == nil { stillSince = Date() }
        else if !still, let t = stillSince { stillSeconds += Date().timeIntervalSince(t); stillSince = nil }
    }
    var stepIndex: Int { Self.steps.firstIndex { $0.ids.contains(stepID) } ?? 0 }

    /// Seconds left of the whole build: the runner's one estimate (ETA lines, nx_build.py TimeLeft), nothing of the app's own
    var etaSeconds: Double? { state == .running ? etaOverride : nil }

    /// The build's priority: written for the runner (<game folder>/logs/priority, read every 10 s; a change restarts the shader step under the new clamp, finished
    /// shaders kept) and passed at the start
    func applyPriority(_ p: String, settings: AppSettings) {
        priority = p
        try? FileManager.default.createDirectory(at: settings.logsURL, withIntermediateDirectories: true)
        try? (p + "\n").data(using: .utf8)?.write(to: settings.logsURL.appendingPathComponent("priority"), options: .atomic)
    }

    func start(settings: AppSettings, mode: Mode) {
        guard !isRunning else { return }
        self.mode = mode
        log.clear()
        state = .running; stepID = "start"; percent = 0; message = "Starting"; sawDone = false; sawError = nil; playable = false; etaOverride = nil
        elapsedBefore = 0; estimateSeconds = nil; estimating = false; counts = [:]; quickStart = settings.quickStart && !settings.testBuild
        startedAt = Date(); stillSeconds = 0; stillSince = nil; waiting = false; overallFloor = 0
        applyPriority(gameRunning ? "low" : settings.buildPriority, settings: settings)

        let fm = FileManager.default
        let script = settings.buildScriptURL
        guard fm.fileExists(atPath: script.path) else { fail("The app's build tools are missing. Download the app again."); return }
        guard settings.pythonPresent else { fail("The app's built-in Python is missing. Download the app again."); return }
        do { try fm.createDirectory(at: settings.logsURL, withIntermediateDirectories: true) } catch {
            fail("The build folder can't be written: \(error.localizedDescription)"); return
        }
        if mode == .fromScratch {   // the game data and code again; saves, keys, packs and shaders stay
            try? fm.removeItem(at: settings.stampsURL)
            try? fm.removeItem(at: settings.readyURL)
        } else if mode == .rebuild {   // the steps this version's build format lists (assets/build-format.json)
            for step in settings.runtimeBuildFormat.redo { try? fm.removeItem(at: settings.stampsURL.appendingPathComponent(step)) }
            try? fm.removeItem(at: settings.readyURL)
        } else if mode == .updateTools {
            try? fm.removeItem(at: settings.stampsURL.appendingPathComponent("tools"))
        }

        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = settings.logsURL.appendingPathComponent("build-" + f.string(from: Date()) + ".log")
        fm.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url); logFileURL = url
        settings.pruneLogs(build: true)   // the newest 20 build logs stay

        var args = ["-E", "-s", "-B", script.path, "--out", settings.cacheURL.path, "--runtime", settings.runtimeURL.path]
        if !settings.basePath.isEmpty, fm.fileExists(atPath: settings.basePath) { args += ["--base", settings.basePath] }
        if !settings.updatePath.isEmpty, fm.fileExists(atPath: settings.updatePath) { args += ["--update", settings.updatePath] }
        if settings.keysPresent { args += ["--keys", settings.keysURL.path] }
        args += ["--storage", settings.storage]
        if settings.testBuild { args.append("--test") } else if settings.quickStart { args.append("--quick-start") }
        if settings.threadsOnly { args.append("--threads-only") }
        if mode == .updateTools { args.append("--update-program") }   // only the game program, into a finished build of an earlier app version
        args += ["--priority", priority]
        record("$ nx_build.py " + (mode == .updateTools ? "(update tools)" : mode == .fromScratch ? "(from scratch)" : mode == .rebuild ? "(rebuild: \(settings.runtimeBuildFormat.redo.joined(separator: ", ")))" : "(continue)")
               + " · app \(AppSettings.appVersion) · runtime \(settings.runtimeVersion ?? "?")")

        let r = ProcessRunner(executable: settings.pythonURL, arguments: args,
                              workingDirectory: settings.runtimeURL, environment: AppSettings.pythonEnvironment())
        r.onStdoutLine = { [weak self] in self?.handle(stdout: $0) }
        r.onStderrLine = { [weak self] in self?.record($0) }
        r.onExit = { [weak self] code in self?.finished(code: code) }
        runner = r
        do { try r.start() } catch { fail("The build could not start: \(error.localizedDescription)") }
    }

    func cancel() {
        guard isRunning else { return }
        if state == .paused { runner?.signalGroup(SIGCONT) }   // a stopped process gets SIGTERM only once it runs again
        state = .cancelling; message = "Stopping"
        runner?.cancel(grace: 10)
    }

    /// Back to the checklist after a finished, stopped or failed build.
    func reset() { if !isRunning { state = .idle } }

    private func handle(stdout line: String) {
        record(line)
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return }
        switch head {
        case "PROGRESS":
            guard parts.count >= 3 else { return }
            stepID = parts[1]
            percent = min(100, max(0, Int(parts[2]) ?? percent))
            message = parts.count > 3 ? parts[3] : ""
        case "ETA":
            etaOverride = parts.count > 1 ? Double(parts[1]) : nil
            if state == .running { overallFloor = max(overallFloor, computedOverall) }
        case "WAITING":
            waiting = parts.count > 1 && parts[1] == "1"
            if state == .running { standStill(waiting) }
        case "COUNT":
            let f = line.split(separator: " ").map(String.init)
            if f.count >= 4, let d = Int(f[2]), let t = Int(f[3]) { counts[f[1]] = (d, t) }
        case "PHASE":
            estimating = parts.count > 1 && parts[1] == "estimating"
        case "ELAPSED_BEFORE":
            elapsedBefore = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        case "ESTIMATE":
            estimateSeconds = parts.count > 1 ? Int(parts[1]) : nil
            if let e = estimateSeconds { record("--- estimate: the whole build takes about \(TimeInterval(e).hmText) on this Mac ---") }
        case "PLAYABLE":
            playable = true; record("--- the game can be played now; the other shaders compile in the background ---")
        case "DONE":
            sawDone = true; percent = 100; stepID = "done"; message = "Ready"
        case "ERROR":
            sawError = parts.dropFirst().joined(separator: " ")
        default: break
        }
    }

    private func record(_ line: String) {
        log.append(line)
        if let d = (line + "\n").data(using: .utf8) { logHandle?.write(d) }
    }

    private func finished(code: Int32) {
        runner = nil
        defer { try? logHandle?.close(); logHandle = nil }
        if state == .cancelling { state = .cancelled; record("--- stopped ---"); return }
        if let e = sawError { state = .failed(Self.plain(e)); return }
        if code == 0 && sawDone { state = .done; return }
        fail(code == 0 ? "The build ended without finishing." : "The build stopped with an error (code \(code)).")
    }

    private func fail(_ msg: String) { state = .failed(msg); record("ERROR " + msg) }

    /// The first line of the script's error, which is written for people; the rest is in the details.
    private static func plain(_ e: String) -> String {
        let first = e.split(separator: "\n").first.map(String.init) ?? e
        return first.hasSuffix(":") ? String(first.dropLast()) + " (see the details)." : first
    }
}

extension TimeInterval {
    /// "1 h 13 min", "42 min", "under a minute"
    var hmText: String {
        let m = Int(self / 60)
        if m < 1 { return "under a minute" }
        return m < 60 ? "\(m) min" : "\(m / 60) h \(String(format: "%02d", m % 60)) min"
    }
    /// "about 6 minutes left", "about 1 h 20 min left", "less than a minute left".
    var etaText: String {
        let m = Int((self / 60).rounded())
        if m < 1 { return "less than a minute left" }
        if m < 60 { return "about \(m) minute\(m == 1 ? "" : "s") left" }
        return "about \(m / 60) h \(m % 60) min left"
    }
}
