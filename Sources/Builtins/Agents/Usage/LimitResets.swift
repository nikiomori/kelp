import Core
import Foundation

/// Tracks the plan limits that ran out and the sessions they stopped, so those sessions can be told to go on at the
/// reset.
/// Limit: kept by this window; a limit that ran out before Kelp opened gets no reset notice.
struct LimitResets {
    /// When Kelp saw the agent's limit run out, and when the last of its full limits resets.
    struct Full: Equatable { var since: Date, until: Date }
    private(set) var full: [String: Full] = [:]   // agent id → its full limits

    /// Returns the agents whose limit just ran out, or now resets later because a weekly limit ran out too. It reads
    /// the readings the sidebar shows.
    mutating func update(_ readings: [UsageGet.Result.Reading], now: Date = Date())
        -> [String]
    {
        var changed: [String] = []
        for reading in readings where reading.limit.percent >= 100 {
            guard let at = reading.resetAt, at > now else { continue }
            let old = full[reading.agent]
            if let old, at <= old.until { continue }
            full[reading.agent] = Full(since: old?.since ?? now, until: at)
            if !changed.contains(reading.agent) { changed.append(reading.agent) }
        }
        return changed
    }

    mutating func end(_ agent: String) -> Full? { full.removeValue(forKey: agent) }

    /// Returns the agent's sessions that stopped while its limit was full and haven't changed status since. A session
    /// that went on by itself at the reset (Claude Code can) changed its status after the reset, so it isn't told
    /// twice. A session the daemon will continue by itself (`Session.continueAt`) needs no asking. The limit is read
    /// from the screen a moment after the turn stopped, so the check allows two minutes of slack.
    static func stopped(_ sessions: [Session], agent: String, _ full: Full) -> [Session] {
        sessions.filter { session in
            guard session.agent == agent, [.done, .error].contains(session.status), session.continueAt == nil,
                let at = session.statusAt
            else {
                return false
            }
            return at >= full.since.addingTimeInterval(-120) && at < full.until
        }
    }
}
