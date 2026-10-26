import Foundation
import Core

extension Sessions {
    /// How long an ended session stays. The app drops an ended session's tab the next time it starts; after that only
    /// its id reaches it (`kelp terminal read`, `kelp wait` in a script). A week covers a window left open that long.
    static let keepEnded: TimeInterval = 7 * 86400

    /// Sessions that ended more than `keepEnded` ago go, records and logs (up to 8 MiB each), and so do logs no record
    /// names. Running and paused ones stay whatever their age. Run a minute after start and daily (`start`).
    func pruneEnded(now: Date = Date()) {
        do {
            for s in try store.sessions() where s.status == .exited && (s.statusAt ?? s.createdAt) < now - Self.keepEnded {
                // A remote one's host is asked only when its agent may still run there, in the background (endOwnTmux).
                discard(s, keepTmux: !s.connectionLost)
            }
            let known = Set(try store.sessions().map(\.id)), fm = FileManager.default
            let logs = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("history"),
                                                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in logs where f.pathExtension == "log" && !known.contains(f.deletingPathExtension().lastPathComponent) {
                // A day old at least: a new session opens its log just before its record is saved.
                guard let at = try f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, at < now - 86400 else { continue }
                try fm.removeItem(at: f)
            }
        } catch { Log.store.error("couldn't prune ended sessions: \(error)") }
    }
}
