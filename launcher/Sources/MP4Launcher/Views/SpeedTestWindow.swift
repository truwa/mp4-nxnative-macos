import SwiftUI
import AppKit

/// The build speed test (Runtime/nx_speedtest.py): a sample of the shaders compiled, and the full build's time projected for this Mac.
/// Players get one cold run sized for under three minutes (--player). Opened with the Option key held, the window shows the developer options:
/// the process count (0 = threads only), comparing against threads only, A-B-B-A order and the measured warm run.
struct SpeedTestWindow: View {
    @Environment(AppModel.self) private var model
    @State private var dev = false
    @State private var share = SpeedTestWindow.playerShare
    @State private var compare = true
    @State private var procs = ProcessInfo.processInfo.activeProcessorCount
    @State private var priority = "normal"
    @State private var abba = true
    @State private var warm = true
    @State private var lines: [String] = []
    @State private var result: [String: Any]?
    @State private var error: String?
    @State private var runner: ProcessRunner?
    /// The run in progress: (run, runs, label, done, total, seconds), from the PROGRESS lines
    @State private var progress: (run: Int, runs: Int, label: String, done: Int, total: Int, secs: Int)?
    @State private var startedAt: Date?

    private var s: AppSettings { model.settings }
    private static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }
    /// nx_speedtest.py player_share: 0.5% (about 100 s of cold run on the M4)
    static let playerShare = 0.5
    private var pkgReady: Bool { (try? FileManager.default.contentsOfDirectory(atPath: s.workURL.appendingPathComponent("shader/pkg").path))?.isEmpty == false }
    private var inputsReady: Bool { FileManager.default.fileExists(atPath: s.cacheURL.appendingPathComponent("inputs").path) }
    private var running: Bool { runner != nil }
    private var comparing: Bool { dev && compare && procs > 0 }
    private var sampleShaders: Int { Int(259_989 * share / 100 * 1.5) }   // a sampled vertex shader brings its pixel shaders (1% gave 3,884 for 2,602 keys)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build speed test").font(.title2.weight(.semibold))
            Text(dev ? "Developer options: compares settings on a sample of the shaders. Other work on the Mac slows the runs; A-B-B-A order keeps a comparison fair."
                     : "Compiles a small sample of the game's shaders (about 2 minutes) and estimates how long the full build takes on this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            panel {
                row("Sample") {
                    Slider(value: $share, in: 0.3...3, step: 0.1).frame(width: 200)
                    Text(String(format: "%.1f%% · ~%@ shaders", share, sampleShaders.formatted())).monospacedDigit().foregroundStyle(.secondary).frame(width: 170, alignment: .trailing)
                }
                if dev {
                    Divider()
                    row("Processes") {
                        Stepper(procs == 0 ? "Threads only" : "\(procs)", value: $procs, in: 0...max(1, Self.cores)).fixedSize()
                        Toggle("Also run threads only (compare)", isOn: $compare).disabled(procs == 0)
                    }
                    if comparing { Divider(); row("Order") { Toggle("A-B-B-A (fair under changing load; twice the runs)", isOn: $abba) } }
                    Divider()
                    row("Warm run") { Toggle("Measure it (instead of the calibrated ratio)", isOn: $warm) }
                }
                Divider()
                row("Priority") {
                    Picker("", selection: $priority) { Text("Normal").tag("normal"); Text("Low (like quick start's background)").tag("utility"); Text("Background").tag("background") }
                        .labelsHidden().fixedSize()
                }
            }
            HStack {
                if !pkgReady && !inputsReady { Text("Choose the game files in the Build window first: the test prepares the shaders from them (under a minute).").font(.caption).foregroundStyle(.red) }
                else if !pkgReady { Text("The shaders are prepared first (under a minute; the build reuses them).").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if running { Button("Stop") { runner?.cancel(grace: 3) } }
                Button("Run test") { start() }.keyboardShortcut(.defaultAction).disabled(running || (!pkgReady && !inputsReady) || model.build.isRunning || model.play.isRunning)
            }
            if running { panel { progressView } }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let r = result { resultsView(r) }
            if dev || !lines.isEmpty && !running {
                panel {
                    ScrollView { Text(lines.joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(minHeight: 60, maxHeight: 140)
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { dev = NSEvent.modifierFlags.contains(.option) }
    }

    /// One bar for the whole test, the run's count and the time passed / left
    @ViewBuilder private var progressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = progress, p.total > 0 {
                let whole = (Double(p.run - 1) + Double(p.done) / Double(p.total)) / Double(max(1, p.runs))
                ProgressView(value: min(1, whole))
                HStack {
                    Text("Run \(p.run) of \(p.runs) · \(p.label) · \(p.done.formatted()) of \(p.total.formatted()) shaders").monospacedDigit()
                    Spacer()
                    if let t0 = startedAt {
                        let passed = Date().timeIntervalSince(t0)
                        let left = whole > 0.05 ? passed / whole - passed : nil
                        Text(Self.ms(Int(passed)) + (left.map { " · about \(Self.ms(Int($0))) left" } ?? "")).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text(lines.last ?? "Starting").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func resultsView(_ r: [String: Any]) -> some View {
        let rows = (r["results"] as? [[String: Any]]) ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimated for the full build on this Mac: about \(Self.hm(r["projected_total_s"] as? Int ?? 0))").font(.headline)
            Text("Shaders about \(Self.hm(r["projected_shader_s"] as? Int ?? 0)), pipelines about \(Self.hm(r["pipelines_estimate_s"] as? Int ?? 0)), plus a minute for the game data. With quick start you can play after a few minutes. Saved in the logs folder; the Build window uses it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if dev {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Setting").bold(); Text("Shaders/min").bold(); Text("Cold / warm s").bold(); Text("Shaders").bold() }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row["label"] as? String ?? "?")
                            Text("\((row["shaders_per_min"] as? Int ?? 0).formatted())").monospacedDigit()
                            Text("\(Int(row["cold_s"] as? Double ?? 0)) / \(Int(row["warm_s"] as? Double ?? 0))\(row["warm_measured"] as? Bool == true ? "" : " (ratio)")").monospacedDigit()
                            Text(Self.hm(row["projected_shader_s"] as? Int ?? 0)).monospacedDigit().bold(row["label"] as? String == r["best"] as? String)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// One panel of the window's single column: full width, the same look as the results box
    private func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 90, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }
    }

    static func hm(_ s: Int) -> String { s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : "\(max(1, s / 60)) min" }
    static func ms(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    private func start() {
        lines = []; result = nil; error = nil; progress = nil; startedAt = Date()
        let script = s.runtimeURL.appendingPathComponent("nx_speedtest.py")
        var args = ["-E", "-s", "-B", script.path, "--game", s.cacheURL.path, "--share", String(format: "%.1f", share), "--priority", priority]
        if dev {
            args += ["--procs", comparing ? "0,\(procs)" : "\(procs)"]
            if comparing && abba { args.append("--abba") }
            if warm { args.append("--warm") }
        } else {
            args.append("--player")
        }
        var env = AppSettings.pythonEnvironment()
        env["PATH"] = [s.runtimeURL.appendingPathComponent("bin").path, s.runtimeURL.appendingPathComponent("dotnet").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["DOTNET_ROOT"] = s.runtimeURL.appendingPathComponent("dotnet").path
        let r = ProcessRunner(executable: s.pythonURL, arguments: args, workingDirectory: s.runtimeURL, environment: env)
        r.onStdoutLine = { line in
            if line.hasPrefix("RESULT "), let d = line.dropFirst(7).data(using: .utf8) { result = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            else if line.hasPrefix("ERROR ") { error = String(line.dropFirst(6)) }
            else if line.hasPrefix("STEP ") { lines.append(String(line.dropFirst(5))) }
            else if line.hasPrefix("PROGRESS ") {
                // PROGRESS <run> <runs> <label words…> <done> <total> <seconds>
                let f = line.split(separator: " ").map(String.init)
                if f.count >= 7, let run = Int(f[1]), let runs = Int(f[2]), let done = Int(f[f.count - 3]), let total = Int(f[f.count - 2]), let secs = Int(f[f.count - 1]) {
                    progress = (run, runs, f[3..<(f.count - 3)].joined(separator: " "), done, total, secs)
                }
            }
        }
        r.onStderrLine = { _ in }
        r.onExit = { _ in runner = nil }
        runner = r
        do { try r.start() } catch { self.error = error.localizedDescription; runner = nil }
    }
}
