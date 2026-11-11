import Foundation
import Observation
import AppKit

/// Every choice the launcher keeps, and where everything lives. All of it is in the build folder
/// (`~/Library/Application Support/mp4launcher` unless the user moves it): `settings.json`, the game folder with the
/// game data, shaders, saves, logs, the copied prod.keys and the resolution packs. Nothing is kept in macOS defaults.
@Observable @MainActor
final class AppSettings {
    let game: Game = .metroidPrime4

    // MARK: Stored choices (settings.json)

    var basePath: String { didSet { save() } }
    var updatePath: String { didSet { save() } }
    /// "native" (1600x900) or "<w>x<h>" (see `resolutionOptions`; the rows come from the game's own code).
    var resolution: String { didSet { save() } }
    var metalHUD: Bool { didSet { save() } }
    /// Start the game from a small app wrapper that macOS recognises as a game (Game Mode in full screen).
    var gameMode: Bool { didSet { save() } }
    /// "plain" or "metalfx" (the runtime upscales the final picture to the window).
    var picture: String { didSet { save() } }
    /// The game's settings in the Settings window (GameOptions): each becomes a switch of the game program at the next Play (gameEnvPairs).
    var opts: GameOptions { didSet { save() } }
    /// "system", "light" or "dark": the launcher's own windows (not the game's).
    var appearance: String { didSet { save(); applyAppearance() } }
    /// What a finished build keeps of the shader work: "minimal", "normal" or "full" (nx_build.py --storage).
    var storage: String { didSet { save() } }
    /// Build the recorded playthrough's shaders first and allow playing while the rest compile (nx_build.py --quick-start).
    var quickStart: Bool { didSet { save() } }
    /// A test build: only the recorded shaders, in a game folder of its own beside the real one (nx_build.py --test).
    var testBuild: Bool { didSet { save(); keysRevision += 1 } }
    /// The shader step in one process with threads instead of a worker process per core (nx_build.py --threads-only): slower, for comparison.
    var threadsOnly: Bool { didSet { save() } }
    /// The build's priority while no game runs: "normal" or "low" (the utility QoS clamp, nx_build.py --priority). While the game runs it is always low.
    var buildPriority: String { didSet { save() } }

    private struct Stored: Codable {
        var basePath = "", updatePath = "", resolution = "native", picture = "plain", appearance = "system"
        var metalHUD = false, gameMode = true
        var storage = "normal", quickStart = true, testBuild = false, threadsOnly = false, buildPriority = "normal"
        var game = GameOptions()

        init() {}
        init(basePath: String, updatePath: String, resolution: String, picture: String, appearance: String,
             metalHUD: Bool, gameMode: Bool, storage: String, quickStart: Bool, testBuild: Bool, threadsOnly: Bool, buildPriority: String, game: GameOptions) {
            self.basePath = basePath; self.updatePath = updatePath; self.resolution = resolution; self.picture = picture
            self.appearance = appearance; self.metalHUD = metalHUD; self.gameMode = gameMode
            self.storage = storage; self.quickStart = quickStart; self.testBuild = testBuild; self.threadsOnly = threadsOnly; self.buildPriority = buildPriority; self.game = game
        }
        /// Missing keys (a settings.json from an older version) keep their defaults.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
            basePath = v(.basePath, ""); updatePath = v(.updatePath, ""); resolution = v(.resolution, "native")
            picture = v(.picture, "plain"); appearance = v(.appearance, "system")
            metalHUD = v(.metalHUD, false); gameMode = v(.gameMode, true)
            storage = v(.storage, "normal"); quickStart = v(.quickStart, true); testBuild = v(.testBuild, false); threadsOnly = v(.threadsOnly, false)
            buildPriority = v(.buildPriority, "normal"); game = v(.game, GameOptions())
        }
    }
    private var loading = true

    // MARK: Folders

    static let bundleID = "local.mp4nxnative"   // the app's bundle identifier (user, 2026-11-10: no "mgt" in the system's folder names); its defaults domain is cleared at start / quit (clearDefaults)
    static var appSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    /// The default build folder; also where `location.json` points elsewhere when the user moved it.
    static var defaultRoot: URL { appSupport.appendingPathComponent("mp4nxnative", isDirectory: true) }
    static var pointerURL: URL { defaultRoot.appendingPathComponent("location.json") }

    private(set) var rootURL: URL
    var settingsURL: URL { rootURL.appendingPathComponent("settings.json") }
    /// The game folder: the real build's, or with `testBuild` a test build's beside it (its keys, saves and resolution packs are the real folder's).
    var cacheURL: URL { testBuild ? rootURL.appendingPathComponent(game.id + "-test", isDirectory: true) : mainGameURL }
    var mainGameURL: URL { rootURL.appendingPathComponent(game.id, isDirectory: true) }
    var userDataURL: URL { mainGameURL.appendingPathComponent("user-data", isDirectory: true) }
    var savesURL: URL { userDataURL.appendingPathComponent("save", isDirectory: true) }
    var logsURL: URL { cacheURL.appendingPathComponent("logs", isDirectory: true) }
    /// Keeps the newest `keep` logs of one kind in logs/ (play logs: "<date>.log"; build logs: "build-<date>.log") and deletes the older ones (user, 2026-11-09:
    /// nothing ever removed them). The date in the name sorts in time order. Other files in logs/ (shader-progress.tsv, priority) are not touched.
    func pruneLogs(build: Bool, keep: Int = 20) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logsURL.path) else { return }
        let mine = names.filter { $0.hasSuffix(".log") && $0.hasPrefix("build-") == build && (build || $0.first?.isNumber == true) }.sorted()
        for old in mine.dropLast(keep) { try? fm.removeItem(at: logsURL.appendingPathComponent(old)) }
    }
    var readyURL: URL { cacheURL.appendingPathComponent("ready.json") }
    var stampsURL: URL { cacheURL.appendingPathComponent(".stamps", isDirectory: true) }
    var keysURL: URL { mainGameURL.appendingPathComponent("keys/prod.keys") }
    var modsDirURL: URL { mainGameURL.appendingPathComponent("mods", isDirectory: true) }
    var gameBinaryURL: URL { cacheURL.appendingPathComponent("build.noindex/tools/dmhost") }
    var workURL: URL { cacheURL.appendingPathComponent("build.noindex", isDirectory: true) }
    /// Every shader the game asks for while playing, in order (DM_PSO_RECORD): the list a later shaders-in-play-order build uses.
    var playedShadersURL: URL { logsURL.appendingPathComponent("shaders-played.tsv") }
    /// The game's app bundle (Game Mode), beside the program it wraps in build.noindex: out of the player's sight, and the .noindex folder keeps Spotlight from listing it
    /// (user, 2026-11-10: MP4 nxnative is the only app a player sees or opens)
    var gameAppURL: URL { cacheURL.appendingPathComponent("build.noindex/MP4 Game.app", isDirectory: true) }
    /// Where the game's bundle was before (the game folder itself): removed on Play
    var oldGameAppURL: URL { cacheURL.appendingPathComponent("MP4 Game.app", isDirectory: true) }
    var gameAppExecutableURL: URL { gameAppURL.appendingPathComponent("Contents/MacOS/mp4-native") }

    init() {
        Self.migrate()
        let root = Self.readPointer() ?? Self.defaultRoot
        rootURL = root
        let s = Self.load(from: root.appendingPathComponent("settings.json")) ?? Self.legacySettings() ?? Stored()
        basePath = s.basePath; updatePath = s.updatePath; resolution = s.resolution; picture = s.picture
        appearance = s.appearance; metalHUD = s.metalHUD; gameMode = s.gameMode; opts = s.game
        storage = ["minimal", "normal", "full"].contains(s.storage) ? s.storage : "normal"; quickStart = s.quickStart; testBuild = s.testBuild; threadsOnly = s.threadsOnly
        buildPriority = ["low", "background"].contains(s.buildPriority) ? "low" : "normal"
#if !DEVELOPER
        testBuild = false; threadsOnly = false   // developer options (Test build, Threads only): not in a release build (user, 2026-11-09: "for us only")
#endif
        loading = false
        save()
        applyAppearance()
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(basePath: basePath, updatePath: updatePath, resolution: resolution, picture: picture, appearance: appearance,
                       metalHUD: metalHUD, gameMode: gameMode, storage: storage, quickStart: quickStart, testBuild: testBuild, threadsOnly: threadsOnly, buildPriority: buildPriority, game: opts)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: settingsURL, options: .atomic) }
    }

    private static func load(from url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func readPointer() -> URL? {
        guard let data = try? Data(contentsOf: pointerURL),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], let p = j["path"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// Moves the build folder setting to `url` (the folder itself is not moved; a build already there is used).
    func changeRoot(to url: URL) {
        let fm = FileManager.default
        if url.standardizedFileURL == Self.defaultRoot.standardizedFileURL {
            try? fm.removeItem(at: Self.pointerURL)
        } else {
            try? fm.createDirectory(at: Self.defaultRoot, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["path": url.path]) { try? data.write(to: Self.pointerURL, options: .atomic) }
        }
        let oldKeys = keysURL
        rootURL = url
        // Keys stored before the folder changed go along (else the build in the new folder ran without them).
        if fm.isReadableFile(atPath: oldKeys.path), !fm.fileExists(atPath: keysURL.path) { try? Self.storeKeys(from: oldKeys, to: keysURL) }
        keysRevision += 1
        if let s = Self.load(from: settingsURL) {
            loading = true
            resolution = s.resolution; metalHUD = s.metalHUD; gameMode = s.gameMode; picture = s.picture; opts = s.game
            if basePath.isEmpty { basePath = s.basePath }
            if updatePath.isEmpty { updatePath = s.updatePath }
            loading = false
        }
        save()
    }

    // MARK: Migration from 0.1 (folder "MP4 Launcher", settings in macOS defaults)

    private static let legacyDomains = [bundleID]

    /// Renames the old folder (instant on the same disk; saves and shaders kept) and leaves no macOS defaults behind.
    private static func migrate() {
        // nxnative launcher: nothing to migrate (a separate app with its own folder)
    }

    /// The 0.1 choices, read once from macOS defaults (then removed). A keys path found there is copied into the
    /// build folder; the path itself is not kept.
    private static func legacySettings() -> Stored? {
        var found: Stored?
        for name in legacyDomains {
            guard let d = UserDefaults.standard.persistentDomain(forName: name), !d.isEmpty else { continue }
            var s = found ?? Stored()
            if let v = d["basePath"] as? String, !v.isEmpty { s.basePath = v }
            if let v = d["updatePath"] as? String, !v.isEmpty { s.updatePath = v }
            if let v = d["resolution"] as? String { s.resolution = v }
            if let v = d["picture"] as? String { s.picture = v }
            for (k, path) in [("metalHUD", \Stored.metalHUD), ("gameMode", \Stored.gameMode)] as [(String, WritableKeyPath<Stored, Bool>)] {
                if let v = d[k] as? Bool { s[keyPath: path] = v }
            }
            if let k = d["keysPath"] as? String, !k.isEmpty {
                let dst = defaultRoot.appendingPathComponent("\(Game.metroidPrime4.id)/keys/prod.keys")
                if !FileManager.default.fileExists(atPath: dst.path) { try? Self.storeKeys(from: URL(fileURLWithPath: k), to: dst) }
            }
            found = s
        }
        return found
    }

    /// Removes every macOS defaults domain of this app (0.1's, and what AppKit writes for window frames).
    static func clearDefaults() {
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
        for name in legacyDomains {
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: prefs.appendingPathComponent(name + ".plist"))   // macOS leaves an empty file
        }
    }

    // MARK: Appearance

    func applyAppearance() {
        switch appearance {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    // MARK: prod.keys (kept only as a copy in the build folder; the original's location is never stored)

    /// Bumped when the stored keys change: keysPresent reads the disk, which SwiftUI does not watch (a chosen file showed no change).
    private var keysRevision = 0
    var keysPresent: Bool { _ = keysRevision; return FileManager.default.isReadableFile(atPath: keysURL.path) }

    enum KeysError: LocalizedError {
        case unreadable, notKeys
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file can't be read."
            case .notKeys: return "That doesn't look like a prod.keys file (no header_key or key_area_key_application lines)."
            }
        }
    }

    func setKeys(from url: URL) throws { try Self.storeKeys(from: url, to: keysURL); keysRevision += 1 }

    private static func storeKeys(from url: URL, to dst: URL) throws {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { throw KeysError.unreadable }
        guard text.contains("header_key"), text.contains("key_area_key_application_") else { throw KeysError.notKeys }
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: dst, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
    }

    func forgetKeys() { try? FileManager.default.removeItem(at: keysURL.deletingLastPathComponent()); keysRevision += 1 }

    // MARK: Runtime and Python (inside the app)

    /// `Runtime/` next to the app bundle (development), else inside the app's Resources.
    static var runtimeURL: URL {
        let bundle = Bundle.main.bundleURL
        let beside = bundle.deletingLastPathComponent().appendingPathComponent("Runtime", isDirectory: true)
        if FileManager.default.fileExists(atPath: beside.path) { return beside }
        return (Bundle.main.resourceURL ?? beside).appendingPathComponent("Runtime", isDirectory: true)
    }
    var runtimeURL: URL { Self.runtimeURL }
    var buildScriptURL: URL { runtimeURL.appendingPathComponent("nx_build.py") }
    var playScriptURL: URL { runtimeURL.appendingPathComponent("nx_play.py") }
    var runtimeVersion: String? {
        try? String(contentsOf: runtimeURL.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    /// The build of this app (make-app.sh stamps the date and time into CFBundleVersion), so testers can tell builds apart
    static var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    /// The app's own Python (Contents/Resources/Python), else a system one (development only).
    var pythonURL: URL {
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("Python/bin/python3")
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        let found = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        return URL(fileURLWithPath: found ?? "/usr/bin/python3")
    }
    var pythonPresent: Bool { FileManager.default.isExecutableFile(atPath: pythonURL.path) }

    /// Environment for the build scripts: the user's Python settings are ignored so nothing outside the app is read or written.
    /// Whether a speed test or a finished build's real times hold for this Mac and builder (nx_speedtest.py --check: VALID / NONE). Off the main thread; false on any error
    func hasValidEstimate() async -> Bool {
        let py = pythonURL, script = runtimeURL.appendingPathComponent("nx_speedtest.py"), game = cacheURL, rt = runtimeURL, env = AppSettings.pythonEnvironment()
        return await Task.detached { () -> Bool in
            let p = Process(); p.executableURL = py
            p.arguments = ["-E", "-s", "-B", script.path, "--game", game.path, "--check"]
            p.currentDirectoryURL = rt; p.environment = env
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).hasPrefix("VALID")
        }.value
    }

    /// A variable set with `launchctl setenv` (nil when it is not set)
    static func launchdEnv(_ name: String) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["getenv", name]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    static func pythonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE", "PYTHONEXECUTABLE", "PIP_CONFIG_FILE", "VIRTUAL_ENV"] { env.removeValue(forKey: k) }
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        if let res = Bundle.main.resourceURL { env["NX_PYTHON"] = res.appendingPathComponent("Python/bin/python3").path }   // the zstd shim's Python
        return env
    }

    // MARK: Build state

    var gameReady: Bool { _ = readyRevision; return FileManager.default.fileExists(atPath: readyURL.path) }
    /// Bumped when ready.json is written outside a build (a found build's "Use it"), so the windows look again
    private var readyRevision = 0
    func readyChanged() { readyRevision += 1 }
    var gameBinaryPresent: Bool { FileManager.default.isExecutableFile(atPath: gameBinaryURL.path) }
    /// Quick start's first part is done but the background part is not (ready.json "partial"): playable, unfinished.
    var buildPartial: Bool { readyInfo?["partial"] as? Bool == true }
    /// Steps are stamped but the build never finished, or only quick start's part is done.
    var buildUnfinished: Bool {
        buildPartial || (!gameReady && !((try? FileManager.default.contentsOfDirectory(atPath: stampsURL.path)) ?? []).isEmpty)
    }
    /// How far the whole build's shaders got: the runner's last record (logs/shader-progress.tsv: time, done of all, all), else the step's own progress file
    /// (<work>/shader/progress.json, left behind when a build stops), nil without either
    var shadersDone: (done: Int, total: Int)? {
        if let t = try? String(contentsOf: logsURL.appendingPathComponent("shader-progress.tsv"), encoding: .utf8),
           let last = t.split(separator: "\n").last(where: { !$0.hasPrefix("#") && !$0.isEmpty }) {
            let f = last.split(separator: "\t", omittingEmptySubsequences: false)
            if f.count >= 3, let d = Int(f[1]), let n = Int(f[2]), n > 0 { return (min(d, n), n) }
        }
        guard let p = try? Data(contentsOf: workURL.appendingPathComponent("shader/progress.json")),
              let j = (try? JSONSerialization.jsonObject(with: p)) as? [String: Any], let d = j["done"] as? Int, let t = j["total"] as? Int, t > 0 else { return nil }
        return (min(d, t), t)
    }
    func stepDone(_ s: String) -> Bool { FileManager.default.fileExists(atPath: stampsURL.appendingPathComponent(s).path) }
    var readyInfo: [String: Any]? {
        guard let data = try? Data(contentsOf: readyURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    var builtRuntimeVersion: String? { readyInfo?["runtime"].map { "\($0)" } }
    var builtDate: String? { readyInfo?["built"] as? String }
    /// The release table this app's runtime carries (Runtime/build-format.json, written by us after testing): this version's build format, and for builds of earlier formats
    /// whether a rebuild is not needed, recommended or mandatory, with the reason the player reads.
    struct BuildFormat { var format = 1, required = 1; var note = "", estimate = ""; var redo: [String] = []; var releases: [Int: (status: String, note: String)] = [:] }
    var runtimeBuildFormat: BuildFormat {
        let url = [runtimeURL.appendingPathComponent("build-format.json"), runtimeURL.appendingPathComponent("assets/build-format.json")].first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url, let data = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return BuildFormat() }
        var rel: [Int: (String, String)] = [:]
        for (k, v) in j["releases"] as? [String: [String: String]] ?? [:] { if let n = Int(k) { rel[n] = (v["status"] ?? "not needed", v["note"] ?? "") } }
        return BuildFormat(format: j["format"] as? Int ?? 1, required: j["required"] as? Int ?? 1, note: j["note"] as? String ?? "",
                           estimate: j["estimate"] as? String ?? "", redo: j["redo"] as? [String] ?? [], releases: rel)
    }
    /// The format the build folder's game was built with (builds from before formats existed count as 1).
    var builtFormat: Int { readyInfo?["build_format"] as? Int ?? 1 }
    /// The shader chain version this app's game program loads (Runtime/nxnative/dm/gfx/nvn/dmsh_chain.h), and the one the build recorded (ready.json)
    var runtimeChain: String? {
        guard let t = try? String(contentsOf: runtimeURL.appendingPathComponent("nxnative/dm/gfx/nvn/dmsh_chain.h"), encoding: .utf8),
              let r = t.range(of: #"DMSH_CHAIN "[0-9a-f]+""#, options: .regularExpression) else { return nil }
        return String(t[r]).replacingOccurrences(of: "DMSH_CHAIN ", with: "").replacingOccurrences(of: "\"", with: "")
    }
    var builtChain: String? { readyInfo?["chain"] as? String }
    /// What a new app version tells the player about the existing build: our release table's word for the build's format, raised to mandatory when this game program
    /// cannot load the build's shaders (another chain version, another pack format). The table can raise the floor, never lower it
    enum RebuildStatus: Equatable { case notNeeded, recommended(String), mandatory(String) }
    var rebuildStatus: RebuildStatus {
        guard gameReady else { return .notNeeded }
        let f = runtimeBuildFormat
        var status = "not needed", note = f.note
        if builtFormat < f.format {
            if let r = f.releases[builtFormat] { status = r.status; if !r.note.isEmpty { note = r.note } }
            else { status = builtFormat < f.required ? "mandatory" : "recommended" }
        }
        let cannotLoad = (runtimeChain != nil && builtChain != runtimeChain) || (readyInfo?["pack_format"] as? Int ?? 1) != 3
        if cannotLoad && status != "mandatory" {
            status = "mandatory"; note = "This version's game program cannot load the shaders of the existing build: they must be compiled again." + (note.isEmpty ? "" : " " + note)
        }
        if status == "mandatory" { return .mandatory(note) }
        return status == "recommended" ? .recommended(note) : .notNeeded
    }
    var rebuildNote: String { switch rebuildStatus { case .recommended(let n), .mandatory(let n): return n; case .notNeeded: return "" } }
    /// A rebuild with this version's tools improves the game (recommended) or is needed for it to work (mandatory).
    var rebuildRecommended: Bool { rebuildStatus != .notNeeded }
    var rebuildRequired: Bool { if case .mandatory = rebuildStatus { return true }; return false }

    /// The app carries newer tools than the build folder has.
    /// A finished build whose game program another version of this app made (ready.json "runtime"), with the same shader chain: the game program is
    /// built again into it (AppModel.installToolsIfNeeded, nx_build.py --update-program, about 30 s). A build that needs a rebuild gets it from the rebuild
    var toolsOutdated: Bool {
        guard gameReady, !buildUnfinished, !rebuildRequired, let mine = runtimeVersion else { return false }
        return builtRuntimeVersion != mine
    }

    /// The space a build takes with each storage option (estimates from 3,000-shader test builds scaled to the 260,000 shaders,
    /// to be corrected after the first full build). The shaders live in a few pack files that store identical libraries once,
    /// so APFS and HFS+ / exFAT drives need the same. (while building, when finished), in GB.
    /// GB of 10^9 bytes, as Finder and the window's free-space figure count. Measured on the M4 (2026-11-10, full Quick start build in a new folder, logs/space.tsv):
    /// Normal peaked at 64.7 GB, its finished size (sources compressed in the cache, space given back right after the shader step). Minimal = Normal without
    /// the 9.8 GB compile cache (the same peak: the cache goes only at the end); Full also keeps the sources and the whole cache (~78 GB). Building = peak + ~5 GB margin.
    static let storageEstimates: [String: (building: Int, finished: Int)] = ["minimal": (70, 55), "normal": (70, 65), "full": (83, 78)]
    static let testBuildEstimate = 35   // the game data (28 GB) and only the recorded shaders and their pipelines (31.5 GB measured) + margin
    static let storageText: [String: String] = [
        "minimal": "Only what the game reads. A later shader fix compiles everything again.",
        "normal": "Also the Metal compile cache: after a shader fix only the changed shaders compile.",
        "full": "For troubleshooting shader problems only: also the shader sources and a per-shader cache. The game is the same; players don't need this.",
    ]
    /// Space the next build still needs on the build folder's disk.
    var neededBytes: Int64 {
        let gb = Int64(testBuild ? Self.testBuildEstimate : (Self.storageEstimates[storage] ?? (80, 65)).building)
        let GB: Int64 = 1_000_000_000   // decimal, as shown (ByteCountFormatter .file); it was GiB (<< 30), so 100 read as "107.37 GB"
        if gameReady && !testBuild && !buildUnfinished { return GB }   // a finished build: only a tools update (a playable quick-start build still needs the rest)
        return (stepDone("romfs") ? max(gb - 28, 10) : gb) * GB   // the game data (28 GB) is already there
    }
    var freeBytes: Int64? {
        var url = rootURL
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Mod packs (the player's own, copied into mods/: frame rate and Level of Detail; resolutions need none since 2026-11-09)

    /// Bumped whenever packs are added or removed, so views that list them refresh at once.
    var packsRevision = 0
    func packsChanged() { packsRevision += 1 }

    /// Installed packs: folders with an exefs patch for main's build id (ResolutionPacks.isPack also accepts the frame-rate and detail packs).
    var installedResolutionMods: [String] {
        _ = packsRevision
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: modsDirURL.path) else { return [] }
        return names.filter { ResolutionPacks.isPack(modsDirURL.appendingPathComponent($0), buildID: game.mainBuildID) }.sorted()
    }

    struct ResolutionOption: Hashable {
        let size: String        // "native" or "<w>x<h>"
        let short: String       // "4K"
        let label: String       // "4K (3840x2160)"
        let dmValue: String     // DM_MP4_RES: 1080 | 1440 | 2160 | 2880 | 4320 | 3440x1440 | 6880x2880
    }
    /// The sizes made from the game's own code (runtime_patches.py / res_sites.py, no pack needed): the 16:9 ladder and the two ultrawide sizes known to work
    static let ownSizes: [(size: String, dm: String)] = [("1920x1080", "1080"), ("2560x1440", "1440"), ("3840x2160", "2160"), ("5120x2880", "2880"), ("7680x4320", "4320"),
                                                          ("3440x1440", "3440x1440"), ("6880x2880", "6880x2880")]
    /// A fixed list (user, 2026-11-09): 900p and the sizes above, none of them from a pack.
    var resolutionOptions: [ResolutionOption] {
        let own = Self.ownSizes.map { o -> ResolutionOption in
            let p = o.size.split(separator: "x").compactMap { Int($0) }
            let n = Self.sizeName(p[0], p[1])
            return ResolutionOption(size: o.size, short: n, label: "\(n) (\(o.size))", dmValue: o.dm)
        }
        return [ResolutionOption(size: "native", short: "900p", label: "900p (1600x900, the game's own)", dmValue: "native")] + own
    }
    static func modSize(_ name: String) -> String? {
        guard let r = name.range(of: #"[0-9]{3,5}x[0-9]{3,5}"#, options: .regularExpression) else { return nil }
        return String(name[r])
    }
    static func sizeName(_ w: Int, _ h: Int) -> String {
        if w * 9 != h * 16 { return "\(h)p ultrawide" }
        switch h { case 1080: return "1080p"; case 1440: return "1440p"; case 2160: return "4K"; case 2880: return "5K"; case 4320: return "8K"; default: return "\(h)p" }
    }
    /// The option Play uses, or nil for 900p.
    var activeResolution: ResolutionOption? {
        guard resolution != "native" else { return nil }
        return resolutionOptions.first { $0.size == resolution }
    }
    var resolutionShort: String { activeResolution?.short ?? "900p" }

    // MARK: Environment for the game process

    var gameEnvironment: [String: String] {
        var env = Self.pythonEnvironment()
        if metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
            // The player's own HUD layout (Apple's MTL_HUD_CONFIG_FILE, set with `launchctl setenv`): passed on when it is set, also when this app was
            // opened before it was set (launchctl getenv)
            if let f = env["MTL_HUD_CONFIG_FILE"] ?? Self.launchdEnv("MTL_HUD_CONFIG_FILE"), !f.isEmpty { env["MTL_HUD_CONFIG_FILE"] = f }
        } else { env.removeValue(forKey: "MTL_HUD_ENABLED"); env.removeValue(forKey: "MTL_HUD_CONFIG_FILE") }
        return env
    }

    /// The packs a setting needs (the player's own, in mods/): the frame-rate and level-of-detail mods (runtime_patches.py)
    static let fpsPackFolders = ["120": "[120FPS Dynamic v1.1.0]", "240": "[240FPS Dynamic v1.1.0]"]
    static let lodPackFolder = "[Level of Detail v1.1.0]"
    func packPresent(_ folder: String) -> Bool { _ = packsRevision; return FileManager.default.fileExists(atPath: modsDirURL.appendingPathComponent(folder).path) }

    /// The game program's switches from the settings (nx_play.py --env): only what differs from the game program's own default, except the pairs it always takes.
    var gameEnvPairs: [(String, String)] {
        let o = opts
        func num(_ v: Double) -> String { String(format: "%.2f", v) }
        var e: [(String, String)] = [("DM_LANG", o.language), ("DM_FULLSCREEN", o.fullscreen ? "1" : "0"), ("DM_PAD_AB", o.padAB), ("DM_PAD_XY", o.padXY),
                                     ("DM_PAD_MERGE", o.mergeControllers ? "1" : "0")]
        // DM_MP4_FPS (120 / 240 with the frame-rate packs) is not sent: held back for a later release (user, 2026-11-09), whatever an older settings.json says
        // DM_MP4_LOD (the Level of Detail pack) is not sent either: mod support is held back for a later release (user, 2026-11-09)
        if o.showOverlay { e.append(("DM_SHOW_FPS", "1")) }
        // MetalFX upscaling (picture == "metalfx", DM_PRESENT_UPSCALE) is not offered for now (user, 2026-11-09): it only sharpens a render smaller than the window
        if o.pictureFit == "fill" { e.append(("DM_PICTURE_FIT", "fill")) }
        if o.console == "handheld" { e.append(("DM_OPMODE", "0")) }
        if o.pacing == "display" { e.append(("DM_PRESENT_INTERVAL", "display")) }
        if !o.rumble { e.append(("DM_RUMBLE", "0")) } else if o.rumbleStrength != 1 { e.append(("DM_RUMBLE_GAIN", num(o.rumbleStrength))) }
        if !o.gyro { e.append(("DM_MOTION", "0")) } else if o.gyroGain != 1 { e.append(("DM_MOTION_GAIN", num(o.gyroGain))) }
        if o.deadZone > 0 { e.append(("DM_STICK_DEADZONE", String(o.deadZone))) }
        if o.mute { e.append(("DM_AUDIO_MUTE", "1")) }
        if o.brightness != 1 { e.append(("DM_BRIGHTNESS", num(o.brightness))) }
        return e
    }

    /// nx_play.py's arguments: the size, dynamic resolution off with a high-resolution pack (unless turned off), the played-shader record, the settings' switches.
    var playArguments: [String] {
        var a = ["--game", cacheURL.path, "--res", activeResolution?.dmValue ?? "native"]
        if opts.recordShaders { a += ["--record", playedShadersURL.path] }
        if activeResolution != nil, opts.steadyRes { a += ["--dynres", "off"] }   // the function stub comes from the game's own code (res_sites.py), no pack needed
        for (k, v) in gameEnvPairs { a += ["--env", "\(k)=\(v)"] }
        return a
    }

    var gameEnvironmentSummary: [(String, String)] {
        let keys = ["MTL_HUD_ENABLED", "MTL_HUD_CONFIG_FILE"]
        let env = gameEnvironment
        return keys.map { ($0, env[$0] ?? "(unset)") }
    }

    /// Removes folders without ever walking them on the main thread: each is renamed into <build folder>/.removing-<date>.noindex (instant on the same drive), then
    /// `rm -rf` deletes that in the background, outside the app. A folder of millions of small files (a build from before the packs) takes minutes to delete, and Finder's
    /// copy or delete of one can hang it and damage the drive's catalog (2026-11-07). Leftovers of an interrupted removal go on the next start (cleanLeftoverRemovals)
    @discardableResult
    func removeSafely(_ urls: [URL]) -> Bool {
        let fm = FileManager.default
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let trash = rootURL.appendingPathComponent(".removing-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6)).noindex", isDirectory: true)
        do { try fm.createDirectory(at: trash, withIntermediateDirectories: true) } catch { return false }
        var ok = true
        for (i, u) in urls.enumerated() where fm.fileExists(atPath: u.path) || (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil {
            do { try fm.moveItem(at: u, to: trash.appendingPathComponent("\(i)-" + u.lastPathComponent)) } catch { ok = false }
        }
        Self.deleteInBackground(trash)
        return ok
    }
    static func deleteInBackground(_ url: URL) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/rm"); p.arguments = ["-rf", url.path]
        p.qualityOfService = .utility; try? p.run()
    }
    func cleanLeftoverRemovals() {
        for n in (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? [] where n.hasPrefix(".removing-") { Self.deleteInBackground(rootURL.appendingPathComponent(n)) }
    }
    /// A build in the layout from before nxnative's library image: its shader cache as one tar file, or a library folder of more than 20,000 files with no image and no pack beside it
    /// (counted only up to that, so a huge folder is never listed whole)
    var oldLayoutBuild: Bool {
        let fm = FileManager.default, cache = workURL.appendingPathComponent("shader/cache")
        if fm.fileExists(atPath: cache.appendingPathComponent("cas.tar").path) { return true }
        for n in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where n.hasPrefix("b-") && !n.contains(".") {
            let dir = cache.appendingPathComponent(n)
            if fm.fileExists(atPath: dir.path + ".img") || fm.fileExists(atPath: dir.appendingPathComponent("shaders.pack").path) { continue }
            guard let d = opendir(dir.path) else { continue }
            var count = 0
            while readdir(d) != nil { count += 1; if count > 20_000 { break } }
            closedir(d)
            if count > 20_000 { return true }
        }
        return false
    }

    /// A copy of the saves before each Play (opts.backupSaves): <game folder>/user-data/save-backups/<date>, the newest 10 kept.
    func backupSavesBeforePlay() -> String? {
        guard opts.backupSaves else { return nil }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: savesURL.path), !items.isEmpty else { return nil }
        let root = userDataURL.appendingPathComponent("save-backups", isDirectory: true)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dst = root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true); try fm.copyItem(at: savesURL, to: dst) }
        catch { return "The saves could not be backed up: \(error.localizedDescription)" }
        let all = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in all.dropLast(10) { try? fm.removeItem(at: root.appendingPathComponent(old)) }
        return "Saves backed up to \(dst.path)"
    }
}


/// The settings the Settings window offers for the game (stored in settings.json as "game"). Defaults are the game program's own behaviour,
/// and both button pairs by position, as on a Switch (user, 2026-11-09; A/B was by label before, after a player found A and B swapped by position).
struct GameOptions: Codable, Equatable {
    var fps = "60", lod = false, steadyRes = true, fullscreen = false, language = "en-US"
    var rumble = true, gyro = true, padAB = "position", padXY = "position"
    var pictureFit = "fit", console = "docked", pacing = "game"
    var rumbleStrength = 1.0, gyroGain = 1.0, brightness = 1.0
    var deadZone = 0
    var mergeControllers = true, mute = false, backupSaves = true, recordShaders = false   // off for players (user, 2026-11-08); testers turn it on in Settings > Advanced
    var showOverlay = false   // DM_SHOW_FPS: the render size and the frame rate in the top left corner of the picture (the Mac front end's overlay)

    init() {}
    /// Missing keys (a settings.json from an older version) keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); let d = GameOptions()
        func v<T: Decodable>(_ k: CodingKeys, _ x: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? x }
        fps = v(.fps, d.fps); lod = v(.lod, d.lod); steadyRes = v(.steadyRes, d.steadyRes); fullscreen = v(.fullscreen, d.fullscreen); language = v(.language, d.language)
        rumble = v(.rumble, d.rumble); gyro = v(.gyro, d.gyro); padAB = v(.padAB, d.padAB); padXY = v(.padXY, d.padXY)
        pictureFit = v(.pictureFit, d.pictureFit); console = v(.console, d.console); pacing = v(.pacing, d.pacing)
        rumbleStrength = v(.rumbleStrength, d.rumbleStrength); gyroGain = v(.gyroGain, d.gyroGain); brightness = v(.brightness, d.brightness)
        deadZone = v(.deadZone, d.deadZone)
        mergeControllers = v(.mergeControllers, d.mergeControllers); mute = v(.mute, d.mute); backupSaves = v(.backupSaves, d.backupSaves); recordShaders = v(.recordShaders, d.recordShaders)
        showOverlay = v(.showOverlay, d.showOverlay)
    }

    static let languages: [(code: String, name: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("fr", "French"), ("fr-CA", "French (Canada)"), ("de", "German"), ("it", "Italian"),
        ("es", "Spanish"), ("es-419", "Spanish (Latin America)"), ("nl", "Dutch"), ("pt", "Portuguese"), ("pt-BR", "Portuguese (Brazil)"), ("ru", "Russian"),
        ("ja", "Japanese"), ("ko", "Korean"), ("zh-Hans", "Chinese (Simplified)"), ("zh-Hant", "Chinese (Traditional)"),
    ]
}
