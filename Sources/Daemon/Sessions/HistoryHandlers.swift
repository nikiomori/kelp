import Core
import Foundation

// Agents' status over time (`session.history`), for the Agents Overview's day and week: read from the trails the
// sessions already keep, so nothing new is stored.

extension SessionHistory: Handled {
    /// Handed the turns' service, which keeps the store and the folder the trails are in (`SessionSetup.root`). The ids
    /// come from the store, so each names a session's own file.
    func handle(_ turns: Turns) throws -> Result {
        let folder = turns.setup.root.appendingPathComponent("history")
        let known = turns.trailsRead.withLock { $0 }
        var kept: [String: (stamp: [Int], changes: [Change])] = [:]
        // A session whose status last changed before the span didn't change in it, so its trail isn't read.
        let entries = try turns.store.sessions().filter { ($0.statusAt ?? $0.createdAt) >= since }.compactMap {
            let trail = StatusTrail(history: folder, session: $0.id), path = trail.url.path
            let stamp = Self.stamp(path)
            let all = known[path].flatMap { $0.stamp == stamp ? $0.changes : nil } ?? StatusTrail.changes(trail.read())
            kept[path] = (stamp, all)
            let changes = StatusTrail.changes(all, since: since)
            return changes.isEmpty ? nil : Entry(session: $0.id, changes: changes)
        }
        turns.trailsRead.withLock { [kept] in $0 = kept }   // only the trails still asked about stay
        return entries
    }

    /// The file's size and modification time to the nanosecond; empty when there's none.
    private static func stamp(_ path: String) -> [Int] {
        var info = stat()
        guard stat(path, &info) == 0 else { return [] }
        return [Int(info.st_size), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
    }
}

extension Methods {
    static let historyMethods: [any Answered.Type] = [SessionHistory.self]
}

extension StatusTrail {
    /// The status changes in a trail's lines ("<time>  up <n>  idle → working  hook: …") from `since` on, with the
    /// status the session had at `since` first. Lines of hooks and other notes are skipped.
    static func changes(_ text: String, since: Date) -> [SessionHistory.Change] { changes(changes(text), since: since) }

    /// Every status change in a trail's lines, oldest first.
    static func changes(_ text: String) -> [SessionHistory.Change] {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // The arrow is looked for first: most lines are hooks', and reading a date is the costly part.
        return text.split(separator: "\n").compactMap { line in
            guard line.contains(" → ") else { return nil }
            let fields = line.components(separatedBy: "  ")
            guard let at = fields.first.flatMap(time.date(from:)),
                let move = fields.dropFirst().first(where: { $0.contains(" → ") }),
                let word = move.components(separatedBy: " → ").last, let status = AgentStatus(rawValue: word)
            else { return nil }
            return .init(at: at, status: status)
        }
    }

    /// The changes from `since` on, with the status the session had at `since` first.
    static func changes(_ all: [SessionHistory.Change], since: Date) -> [SessionHistory.Change] {
        var out = all.filter { $0.at >= since }
        if let before = all.last(where: { $0.at < since }), !out.isEmpty {
            out.insert(.init(at: since, status: before.status), at: 0)
        }
        return out
    }
}
