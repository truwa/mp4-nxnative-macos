import Foundation
import Observation
import AppKit

/// Game menu > Build for iPad / iPhone…: runs `nx_build_ios.py` (an unsigned IPA and the game file in a folder, from the finished Mac build) and turns its
/// PROGRESS / RESULT / DONE / ERROR lines into a bar and a message. Experimental (user, 2026-11-12/13): signing, installing and copying the game file are the player's.
/// Every line also goes to `<game folder>/logs/ios-build-<date>.log`. The Mac build (BuildController) and its window stay as they are.
@Observable @MainActor
final class IOSBuildController {
    enum State: Equatable { case idle, running, cancelling, done, cancelled; case failed(String) }

    private(set) var state: State = .idle
    private(set) var percent = 0
    private(set) var message = ""
    private(set) var resultURL: URL?
    private(set) var startedAt: Date?
    private(set) var logFileURL: URL?
    let log = LogStore()
    private var runner: ProcessRunner?
    private var logHandle: FileHandle?
    private var sawDone = false
    private var sawError: String?

    var isRunning: Bool { state == .running || state == .cancelling }

    /// The output folder: <build folder>/<title ID>/iPad build (on the build's volume, so the 28 GB game file is a hard link, not a copy)
    static func defaultDestination(_ s: AppSettings) -> URL { s.mainGameURL.appendingPathComponent("iPad build", isDirectory: true) }

    func start(settings: AppSettings, destination: URL) {
        guard !isRunning else { return }
        log.clear()
        state = .running; percent = 0; message = "Starting"; sawDone = false; sawError = nil; resultURL = nil; startedAt = Date()
        let fm = FileManager.default
        let script = settings.runtimeURL.appendingPathComponent("nx_build_ios.py")
        guard fm.fileExists(atPath: script.path) else { fail("The app's iPad build tools are missing. Download the app again."); return }
        guard settings.pythonPresent else { fail("The app's built-in Python is missing. Download the app again."); return }
        let logs = settings.mainGameURL.appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = logs.appendingPathComponent("ios-build-" + f.string(from: Date()) + ".log")
        fm.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url); logFileURL = url

        var args = ["-E", "-s", "-B", script.path, "--game", settings.mainGameURL.path, "--runtime", settings.runtimeURL.path, "--dest", destination.path]
        if settings.keysPresent { args += ["--keys", settings.keysURL.path] }
        record("$ nx_build_ios.py · app \(AppSettings.appVersion) · runtime \(settings.runtimeVersion ?? "?") · to \(destination.path)")
        let r = ProcessRunner(executable: settings.pythonURL, arguments: args, workingDirectory: settings.runtimeURL, environment: AppSettings.pythonEnvironment())
        r.onStdoutLine = { [weak self] in self?.handle(stdout: $0) }
        r.onStderrLine = { [weak self] in self?.record($0) }
        r.onExit = { [weak self] code in self?.finished(code: code) }
        runner = r
        do { try r.start() } catch { fail("The iPad build could not start: \(error.localizedDescription)") }
    }

    func cancel() {
        guard isRunning else { return }
        state = .cancelling; message = "Stopping"
        runner?.cancel(grace: 10)
    }

    func reset() { if !isRunning { state = .idle } }

    private func handle(stdout line: String) {
        record(line)
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return }
        switch head {
        case "PROGRESS":
            guard parts.count >= 3 else { return }
            percent = max(percent, min(100, max(0, Int(parts[2]) ?? percent)))   // the bar never goes back
            message = parts.count > 3 ? parts[3] : ""
        case "RESULT":
            resultURL = URL(fileURLWithPath: String(line.dropFirst("RESULT ".count)), isDirectory: true)
        case "DONE":
            sawDone = true; percent = 100; message = "Done"
        case "ERROR":
            sawError = String(line.dropFirst("ERROR ".count))
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
        if let e = sawError { state = .failed(e); return }
        if code == 0 && sawDone { state = .done; return }
        fail(code == 0 ? "The iPad build ended without finishing." : "The iPad build stopped with an error (code \(code)).")
    }

    private func fail(_ msg: String) { state = .failed(msg); record("ERROR " + msg) }
}
