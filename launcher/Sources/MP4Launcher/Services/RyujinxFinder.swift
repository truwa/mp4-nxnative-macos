import Foundation

/// Finds the player's own files through an existing Ryujinx setup: prod.keys in its system folder, and the game and its
/// update in the game folders listed in its Config.json. Read only: nothing in Ryujinx's folders or the game folders is
/// changed, and nothing is copied.
struct RyujinxFinder {
    struct Result {
        var keys: String?
        var base: String?
        var update: String?
        var gameDirs: [String] = []
        var sources: [String] = []   // which setups were looked at, e.g. "Ryujinx and Astris"
        var packs: [URL] = []        // resolution packs in their mods folders
        var found: Bool { keys != nil || base != nil || update != nil || !packs.isEmpty }
    }

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ryujinx", isDirectory: true)
    }

    /// The Ryujinx folders to look in: Ryujinx's own, and the one Astris is set to use (from its preferences' folder
    /// bookmark, when it does not use the default). Only read when the player presses Scan.
    static var roots: [(URL, String)] {
        var out: [(URL, String)] = []
        if FileManager.default.fileExists(atPath: root.path) { out.append((root, "Ryujinx")) }
        let astris = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/V380-Ori.Astris/Data/Library/Preferences/V380-Ori.Astris.plist")
        if let dict = NSDictionary(contentsOf: astris), let data = dict["RyujinxBaseDirBookmark"] as? Data {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: u.path) {
                if let i = out.firstIndex(where: { $0.0.standardizedFileURL == u.standardizedFileURL }) { out[i].1 += " and Astris" }
                else { out.append((u, "Astris")) }
            }
        }
        return out
    }

    /// `titleID` is the base game's (…2000); its update is the same id with …800 at the end.
    static func find(titleID: String) -> Result {
        var r = Result()
        let fm = FileManager.default
        for (root, label) in roots {
            r.sources.append(label)
            let keys = root.appendingPathComponent("system/prod.keys")
            if r.keys == nil, fm.isReadableFile(atPath: keys.path) { r.keys = keys.path }
            let mods = root.appendingPathComponent("mods/contents/\(titleID.lowercased())", isDirectory: true)
            for p in ResolutionPacks.packs(in: mods, buildID: Game.metroidPrime4.mainBuildID, depth: 1)
            where !r.packs.contains(where: { $0.lastPathComponent == p.lastPathComponent }) { r.packs.append(p) }
            let config = root.appendingPathComponent("Config.json")
            if let data = try? Data(contentsOf: config),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let dirs = json["game_dirs"] as? [String] {
                for d in dirs where !r.gameDirs.contains(d) { r.gameDirs.append(d) }
            }
        }
        let base = titleID.lowercased(), update = String(base.dropLast(3)) + "800"
        var baseHits: [String] = [], updateHits: [String] = []
        for dir in r.gameDirs {
            for file in files(in: URL(fileURLWithPath: dir, isDirectory: true), depth: 4) {
                let ext = file.pathExtension.lowercased()
                guard ext == "nsp" || ext == "xci" else { continue }
                switch kind(of: file, base: base, update: update) {
                case .base: baseHits.append(file.path)
                case .update: updateHits.append(file.path)
                case nil: break
                }
            }
        }
        r.base = baseHits.sorted().first
        r.update = updateHits.sorted().first
        return r
    }

    enum Kind { case base, update }

    /// What a chosen or dropped file is: the base game, the update, or neither (nil).
    static func classify(_ url: URL, titleID: String) -> Kind? {
        let base = titleID.lowercased()
        return kind(of: url, base: base, update: String(base.dropLast(3)) + "800")
    }
    /// True when an NSP's ticket names a title (so `classify` decided from the file's contents, not its name).
    static func hasTicket(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "nsp" && (pfs0Names(url)?.contains { $0.lowercased().hasSuffix(".tik") } ?? false)
    }
    /// The base game, the update or prod.keys inside a dropped folder.
    static func search(_ dir: URL, titleID: String) -> (base: URL?, update: URL?, keys: URL?) {
        var b: URL?, u: URL?, k: URL?
        for f in files(in: dir, depth: 3) {
            let ext = f.pathExtension.lowercased()
            if f.lastPathComponent.lowercased() == "prod.keys" { k = k ?? f; continue }
            guard ext == "nsp" || ext == "xci" else { continue }
            switch classify(f, titleID: titleID) {
            case .base: b = b ?? f
            case .update: u = u ?? f
            case nil: break
            }
        }
        return (b, u, k)
    }

    /// An NSP names its ticket "<rights id>.tik", and a rights id starts with the title id: that decides base or update.
    /// An XCI has no ticket in its outer table, so the file name decides (title id, or "Metroid Prime 4" and no "update").
    private static func kind(of url: URL, base: String, update: String) -> Kind? {
        if url.pathExtension.lowercased() == "nsp", let names = pfs0Names(url) {
            let ids = names.map { $0.lowercased() }
            if ids.contains(where: { $0.hasPrefix(update) && $0.hasSuffix(".tik") }) { return .update }
            if ids.contains(where: { $0.hasPrefix(base) && $0.hasSuffix(".tik") }) { return .base }
        }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let flat = name.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let isNSP = url.pathExtension.lowercased() == "nsp"
        if name.contains(update) { return isNSP ? .update : nil }
        guard name.contains(base) || flat.contains("metroidprime4") else { return nil }
        if flat.contains("update") || flat.contains("dlc") { return isNSP && flat.contains("update") ? .update : nil }
        return .base
    }

    /// File names in an NSP's PFS0 header (reads only the header and its string table).
    private static func pfs0Names(_ url: URL) -> [String]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 16), head.count == 16, head.prefix(4) == Data("PFS0".utf8) else { return nil }
        let le32 = { (d: Data, o: Int) -> Int in Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 | Int(d[d.startIndex + o + 2]) << 16 | Int(d[d.startIndex + o + 3]) << 24 }
        let count = le32(head, 4), strSize = le32(head, 8)
        guard count > 0, count < 4096, strSize > 0, strSize < 1 << 20 else { return nil }
        guard let rest = try? h.read(upToCount: count * 24 + strSize), rest.count == count * 24 + strSize else { return nil }
        let table = rest.suffix(strSize)
        return table.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private static func files(in dir: URL, depth: Int) -> [URL] {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for u in items {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { out += files(in: u, depth: depth - 1) } else { out.append(u) }
        }
        return out
    }
}
