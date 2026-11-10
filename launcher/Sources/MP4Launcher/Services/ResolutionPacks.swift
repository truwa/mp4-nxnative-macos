import Foundation

/// The player's own resolution packs (downloaded by the player): checked and copied into `<game folder>/mods`.
/// The app ships none and downloads none.
enum ResolutionPacks {
    /// A pack folder: `exefs/*.pchtxt` for main's build id and `cheats/<build id>.txt` (the scan visor fix).
    static func isPack(_ dir: URL, buildID: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("cheats/\(buildID).txt").path),
              let exefs = try? fm.contentsOfDirectory(at: dir.appendingPathComponent("exefs"), includingPropertiesForKeys: nil) else { return false }
        return exefs.contains { url in
            guard url.pathExtension.lowercased() == "pchtxt", let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.range(of: "@nsobid-\(buildID)", options: .caseInsensitive) != nil
        }
    }

    /// A mod folder with an exefs patch for main's build id (resolution packs and the dynamic-resolution switch).
    static func isMod(_ dir: URL, buildID: String) -> Bool {
        guard let exefs = try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("exefs"), includingPropertiesForKeys: nil) else { return false }
        return exefs.contains { url in
            guard url.pathExtension.lowercased() == "pchtxt", let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.range(of: "@nsobid-\(buildID)", options: .caseInsensitive) != nil
        }
    }

    /// Mod folders at or below `url` (a folder), at most `depth` levels down.
    static func packs(in url: URL, buildID: String, depth: Int = 4) -> [URL] {
        if isMod(url, buildID: buildID) { return [url] }
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .flatMap { packs(in: $0, buildID: buildID, depth: depth - 1) }
    }

    enum InstallError: LocalizedError {
        case unzip, none
        var errorDescription: String? {
            switch self {
            case .unzip: return "That zip couldn't be opened."
            case .none: return "No resolution pack for Metroid Prime 4 1.1.0 was found in it."
            }
        }
    }

    /// Copies every pack found in a dropped `.zip` or folder into `modsDir`; returns their names.
    static func install(from url: URL, into modsDir: URL, buildID: String) throws -> [String] {
        let fm = FileManager.default
        var source = url, temp: URL?
        if url.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("mp4nxnative-pack-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, t.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { try? fm.removeItem(at: t); throw InstallError.unzip }
            source = t; temp = t
        }
        defer { if let temp { try? fm.removeItem(at: temp) } }
        let found = packs(in: source, buildID: buildID)
        guard !found.isEmpty else { throw InstallError.none }
        return try copy(found, into: modsDir)
    }

    static func copy(_ packs: [URL], into modsDir: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
        var names: [String] = []
        for p in packs {
            let dst = modsDir.appendingPathComponent(p.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: p, to: dst)
            names.append(p.lastPathComponent)
        }
        return names
    }
}

/// What the "This Mac" row shows.
enum MacInfo {
    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf)
        return s.isEmpty ? "Apple silicon" : s
    }
    static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    static var macOSSupported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 }
}
