import Foundation
import Core

/// Plan limits that ran out, and the sessions they stopped: at the reset those can be told to go on.
/// Limit: kept by this window; a limit that ran out before Kelp opened gets no reset notice.
struct LimitResets {
    /// Since Kelp saw the agent's limit run out, until the last of its full limits resets.
    struct Full: Equatable { var since: Date, until: Date }
    private(set) var full: [String: Full] = [:]   // agent id → its full limits

    /// Agents whose limit just ran out, or now resets later (a weekly one ran out too), from the readings the sidebar shows.
    mutating func update(_ readings: [(agent: String, limit: UsageGet.Limit, resetAt: Date?)], now: Date = Date()) -> [String] {
        var changed: [String] = []
        for r in readings where r.limit.percent >= 100 {
            guard let at = r.resetAt, at > now else { continue }
            let old = full[r.agent]
            if let old, at <= old.until { continue }
            full[r.agent] = Full(since: old?.since ?? now, until: at)
            if !changed.contains(r.agent) { changed.append(r.agent) }
        }
        return changed
    }

    mutating func end(_ agent: String) -> Full? { full.removeValue(forKey: agent) }

    /// The agent's sessions that stopped while its limit was full and haven't moved since. One that went on by itself at
    /// the reset (Claude Code can) changed its status after it, so it isn't told twice, and one the daemon will go on with
    /// (`Session.continueAt`) needs no asking. The limit is read from the screen a moment after the turn stopped: two minutes
    /// of slack.
    static func stopped(_ sessions: [Session], agent: String, _ f: Full) -> [Session] {
        sessions.filter { s in
            guard s.agent == agent, [.done, .error].contains(s.status), s.continueAt == nil, let at = s.statusAt else { return false }
            return at >= f.since.addingTimeInterval(-120) && at < f.until
        }
    }
}
