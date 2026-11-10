import Foundation
import AppKit
import Observation

/// Runs `prepare_shaders.py --background` as a managed, pausable background job.
/// The script is resumable, so Stop is always safe; the game may run alongside.
@Observable @MainActor
final class ShaderPrepController {
    enum State: Equatable {
        case idle, running, paused, stopping, stopped, finished
        case failed(String)
    }

    static let requiredFreeBytes: Int64 = 18 << 30

    private(set) var state: State = .idle
    private(set) var phase = ""          // prepare / enumerate / translate / compile / report
    private(set) var percent = 0
    private(set) var message = ""
    private(set) var startedAt: Date?
    /// Summary of the newest report.json in the cache, if any.
    private(set) var reportSummary: String?
    private(set) var reportComplete = false
    /// True when `<cache>/build/shader-cache/rt-*/prepared.json` exists: the cache ships prepared; the job is only a refresh.
    private(set) var cachePrepared = false
    var isPrepared: Bool { cachePrepared || reportComplete }
    let log = LogStore(limit: 3000)
    private var runner: ProcessRunner?
    private var sawReport = false
    private var sawError: String?
    private var translateTotal = 0
    private var compileTotal = 0
    /// For the Play window's shader panel: totals from the last report (or the prepared cache's marker) and, while a
    /// run is going, the current step's count.
    private(set) var totalCount: Int?
    private(set) var translatedCount: Int?
    private(set) var compiledCount: Int?
    private(set) var stepDone = 0
    private(set) var stepTotal = 0
    private var terminateObserver: Any?

    var isActive: Bool { state == .running || state == .paused || state == .stopping }
    private var etaFrom: (Date, Int)?

    /// Seconds left while compiling (by far the longest part), from the rate since this run reached the compile phase.
    var etaSeconds: Double? {
        guard state == .running, let (t0, p0) = etaFrom, percent > p0 else { return nil }
        let dt = Date().timeIntervalSince(t0)
        guard dt > 30 else { return nil }
        return dt / Double(percent - p0) * Double(100 - percent)
    }

    /// The Play window's shader line.
    var playLine: String {
        switch state {
        case .running: return "Shaders: \(percent)% ready" + (etaSeconds.map { " · \($0.etaText)" } ?? "")
        case .paused: return "Shaders: paused at \(percent)%"
        case .stopping: return "Shaders: stopping"
        case .failed(let m): return "Shaders: \(m)"
        default: return isPrepared ? "Shaders ready ✓" : (state == .stopped ? "Shaders: stopped at \(percent)%" : "Shaders not prepared yet")
        }
    }

    init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runner?.signalGroup(SIGTERM) }
            }
    }

    /// One line for the Play screen: "preparing 42%", "paused 42%", "prepared", …
    var statusLine: String {
        switch state {
        case .idle: return isPrepared ? "prepared" + (reportSummary.map { " · \($0)" } ?? "") : (reportSummary ?? "not prepared")
        case .running: return "preparing \(percent)%" + (message.isEmpty ? "" : " · \(message)")
        case .paused: return "paused at \(percent)%"
        case .stopping: return "stopping…"
        case .stopped: return "stopped at \(percent)%; Prepare again to resume"
        case .finished: return reportSummary.map { "prepared · \($0)" } ?? "prepared"
        case .failed: return "failed"
        }
    }

    // MARK: Disk space

    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
    static func freeDescription(at url: URL) -> String {
        guard let b = freeBytes(at: url) else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    static func enoughDisk(at url: URL) -> Bool { (freeBytes(at: url) ?? 0) >= requiredFreeBytes }

    // MARK: Control

    func start(settings: AppSettings) {
        return   // nxnative: every shader is compiled by the build itself (nx_build.py); no separate preparation yet
        guard !isActive else { return }
        let script = settings.runtimeURL.appendingPathComponent("scripts/prepare_shaders.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            state = .failed("prepare_shaders.py not found in the runtime bundle (the app is incomplete; download it again)."); return
        }
        guard settings.gameReady, settings.gameBinaryPresent else {
            state = .failed("build the game first"); return
        }
        guard settings.pythonPresent else { state = .failed("the app's built-in Python is missing"); return }
        guard Self.enoughDisk(at: settings.cacheURL) else {
            state = .failed("not enough free space (\(ByteCountFormatter.string(fromByteCount: Self.requiredFreeBytes, countStyle: .file)) needed, \(Self.freeDescription(at: settings.cacheURL)) free)"); return
        }

        log.clear()
        state = .running; phase = "prepare"; percent = 0; message = "Starting…"
        sawReport = false; sawError = nil; translateTotal = 0; compileTotal = 0; startedAt = Date(); etaFrom = nil

        // Run python in its own process group so pause/stop reach the translator and compiler children too.
        let bootstrap = "import os, sys; os.setpgrp(); os.execv(sys.executable, [sys.executable] + sys.argv[1:])"
        let args = ["-E", "-s", "-B", "-c", bootstrap, script.path, "--game-root", settings.cacheURL.path, "--background"]
        log.append("$ \(settings.pythonURL.path) \(script.path) --game-root \"\(settings.cacheURL.path)\" --background")
        let env = AppSettings.pythonEnvironment()
        let r = ProcessRunner(executable: settings.pythonURL, arguments: args, workingDirectory: settings.runtimeURL, environment: env)
        r.onStdoutLine = { [weak self] in self?.handle($0, stderr: false) }
        r.onStderrLine = { [weak self] in self?.handle($0, stderr: true) }
        r.onExit = { [weak self] code in self?.finished(code: code, settings: settings) }
        runner = r
        do { try r.start() } catch { state = .failed("Could not start: \(error.localizedDescription)") }
    }

    func pause() {
        guard state == .running else { return }
        runner?.signalGroup(SIGSTOP); state = .paused
    }
    func resume() {
        guard state == .paused else { return }
        runner?.signalGroup(SIGCONT); state = .running
    }
    func stop() {
        guard state == .running || state == .paused else { return }
        if state == .paused { runner?.signalGroup(SIGCONT) }
        state = .stopping
        runner?.signalGroup(SIGTERM)
        let r = runner
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { r?.signalGroup(SIGKILL) }
    }

    // MARK: Output parsing

    private func handle(_ line: String, stderr: Bool) {
        log.append(line)
        if stderr {
            if line.contains("GiB needed") { sawError = line }
            return
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let tag = parts.first else { return }
        switch tag {
        case "[prepare]":
            phase = "prepare"; message = "Preparing"
        case "[translate]":
            phase = "translate"
            if parts.count >= 2, let (i, n) = fraction(parts[1]) {
                translateTotal = n; percent = n == 0 ? 15 : Int(15.0 * Double(i) / Double(n)); message = "Translating \(i) of \(n)"
                stepDone = i; stepTotal = n
            } else if let idx = parts.firstIndex(of: "to"), idx >= 1, let n = Int(parts[idx - 1]) {
                translateTotal = n; message = n == 0 ? "Translation already done" : "Translating \(n) shaders"
                if n == 0 { percent = 15 }
            }
        case "[compile]":
            phase = "compile"
            if parts.count >= 2, let (i, n) = fraction(parts[1]) {
                compileTotal = n; percent = n == 0 ? 100 : 15 + Int(85.0 * Double(i) / Double(n)); message = "Compiling \(i) of \(n)"
                stepDone = i; stepTotal = n
                if etaFrom == nil { etaFrom = (Date(), percent) }
            } else if parts.count >= 2, let n = Int(parts[1]), parts.dropFirst(2).first == "to" {
                compileTotal = n; percent = max(percent, 15); message = n == 0 ? "Compilation already done" : "Compiling \(n) shaders"
            } else if line.contains("stopping:") {
                message = String(line.dropFirst("[compile] ".count))
            }
        case "[report]":
            phase = "report"; sawReport = true; percent = 100; message = "Report written"
        default: break
        }
    }

    private func fraction(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: "/")
        guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { return nil }
        return (a, b)
    }

    private func finished(code: Int32, settings: AppSettings) {
        runner = nil
        refreshReport(settings: settings)
        if state == .stopping { state = .stopped; log.append("--- stopped ---"); return }
        if let e = sawError { state = .failed(e); return }
        if code == 0 && sawReport { state = .finished; return }
        state = .failed(code == 0 ? "Ended without a report." : "Exited with code \(code). See the log.")
    }

    // MARK: Report

    /// Reads the newest `<cache>/shader-prep/run-*/report.json`.
    func refreshReport(settings: AppSettings) {
        cachePrepared = settings.gameReady; reportComplete = settings.gameReady
        reportSummary = settings.gameReady ? "compiled by the build" : nil
        return
        let prep = settings.cacheURL.appendingPathComponent("shader-prep", isDirectory: true)
        let fm = FileManager.default
        cachePrepared = false
        let shaderCache = settings.cacheURL.appendingPathComponent("build/shader-cache", isDirectory: true)
        if let chains = try? fm.contentsOfDirectory(at: shaderCache, includingPropertiesForKeys: nil) {
            for chain in chains where chain.lastPathComponent.hasPrefix("rt-") {
                let marker = chain.appendingPathComponent("prepared.json")
                guard let data = try? Data(contentsOf: marker) else { continue }
                cachePrepared = true
                totalCount = nil; translatedCount = nil; compiledCount = nil
                if let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let t = m["translated"] as? Int, let c = m["compiled"] as? Int {
                    reportSummary = "\(c) compiled, \(t) translated (\(chain.lastPathComponent))"
                    translatedCount = t; compiledCount = c; totalCount = max(t, c)
                } else {
                    reportSummary = chain.lastPathComponent
                }
                reportComplete = true
                return
            }
        }
        guard let runs = try? fm.contentsOfDirectory(at: prep, includingPropertiesForKeys: nil) else {
            reportSummary = nil; reportComplete = false; return
        }
        let reports = runs.filter { $0.lastPathComponent.hasPrefix("run-") }
            .map { $0.appendingPathComponent("report.json") }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { (fm.modificationDate($0) ?? .distantPast) > (fm.modificationDate($1) ?? .distantPast) }
        guard let newest = reports.first, let data = try? Data(contentsOf: newest),
              let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            reportSummary = nil; reportComplete = false; return
        }
        let selected = r["selected"] as? Int ?? 0
        let compiled = (r["compile"] as? [String: Any])?["ok"] as? Int ?? 0
        let translatedOK = (r["translate"] as? [String: Any])?["ok"] as? Int ?? 0
        let notDone = ((r["translate"] as? [String: Any])?["not done"] as? Int ?? 0)
                    + ((r["compile"] as? [String: Any])?["not done"] as? Int ?? 0)
        let written = r["written"] as? String ?? ""
        reportSummary = "\(compiled) of \(selected) shaders compiled (\(translatedOK) translated), \(written)"
        totalCount = selected; translatedCount = translatedOK; compiledCount = compiled
        reportComplete = selected > 0 && notDone == 0
    }
}

private extension FileManager {
    func modificationDate(_ url: URL) -> Date? {
        (try? attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
