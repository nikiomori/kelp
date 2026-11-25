import Core
import Foundation

// Agents' status over time (`session.history`), for the Agents Overview's day and week: read from the trails the
// sessions already keep, so nothing new is stored.

extension SessionHistory: Handled {
    /// Handed the turns' service, which keeps the store and the folder the trails are in (`SessionSetup.root`). The ids
    /// come from the store, so each names a session's own file.
    func handle(_ turns: Turns) throws -> Result {
        let folder = turns.setup.root.appendingPathComponent("history")
        // A session whose status last changed before the span didn't change in it, so its trail isn't read.
        return try turns.store.sessions().filter { ($0.statusAt ?? $0.createdAt) >= since }.compactMap {
            let changes = StatusTrail.changes(StatusTrail(history: folder, session: $0.id).read(), since: since)
            return changes.isEmpty ? nil : Entry(session: $0.id, changes: changes)
        }
    }
}

extension Methods {
    static let historyMethods: [any Answered.Type] = [SessionHistory.self]
}

extension StatusTrail {
    /// The status changes in a trail's lines ("<time>  up <n>  idle → working  hook: …") from `since` on, with the
    /// status the session had at `since` first. Lines of hooks and other notes are skipped.
    static func changes(_ text: String, since: Date) -> [SessionHistory.Change] {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var before: AgentStatus?, out: [SessionHistory.Change] = []
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "  ")
            guard let at = fields.first.flatMap(time.date(from:)),
                let move = fields.dropFirst().first(where: { $0.contains(" → ") }),
                let word = move.components(separatedBy: " → ").last, let status = AgentStatus(rawValue: word)
            else { continue }
            if at < since { before = status } else { out.append(.init(at: at, status: status)) }
        }
        if let before, !out.isEmpty { out.insert(.init(at: since, status: before), at: 0) }
        return out
    }
}
