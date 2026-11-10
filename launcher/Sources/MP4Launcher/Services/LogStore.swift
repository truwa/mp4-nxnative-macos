import Foundation
import Observation

/// A bounded in-memory log for display.
@Observable @MainActor
final class LogStore {
    private(set) var lines: [String] = []
    let limit: Int

    init(limit: Int = 5000) { self.limit = limit }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
    func clear() { lines.removeAll() }
    var text: String { lines.joined(separator: "\n") }
    func tail(_ n: Int) -> [String] { Array(lines.suffix(n)) }
}
