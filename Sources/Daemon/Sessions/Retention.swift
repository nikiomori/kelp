import Core
import Foundation

extension Sessions {
    /// How long an ended session stays. The app drops an ended session's tab the next time it starts; after that only
    /// its id reaches it (`kelp terminal read`, `kelp wait` in a script). A week covers a window left open that long.
    static let keepEnded: TimeInterval = 7 * 86400

    /// Removes sessions that ended more than `keepEnded` ago, with their records and logs (up to 8 MiB each), and the
    /// logs and trails no record names. Running and paused sessions stay whatever their age. It runs a minute after
    /// start and then daily (`start`).
    func pruneEnded(now: Date = Date()) {
        do {
            for session in try store.sessions()
            where session.status == .exited && (session.statusAt ?? session.createdAt) < now - Self.keepEnded {
                // A remote session's host is asked only when its agent may still run there in the background
                // (endOwnTmux).
                discard(session, keepTmux: !session.connectionLost)
            }
            let left = try store.sessions(), known = Set(left.map(\.id)), fm = FileManager.default
            ScratchChats(root: root).sweep(keeping: Set(left.map(\.cwd)), now: now)
            let logs = fm.items(in: root.appendingPathComponent("history"))
            for log in logs
            where ["log", "trail"].contains(log.pathExtension)
                && !known.contains(log.deletingPathExtension().lastPathComponent)
            {
                // Only files a day old or more go, because a new session opens its log just before its record is saved.
                guard let at = try log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                    at < now - 86400
                else { continue }
                try fm.removeItem(at: log)
            }
        } catch { Log.store.error("couldn't prune ended sessions: \(error)") }
    }
}
