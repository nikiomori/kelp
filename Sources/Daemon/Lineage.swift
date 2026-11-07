import Core
import Foundation

/// Who started whom, read from the records: the same for the rules (`Daemon.allow`) and for who a caller is (`Callers`).
extension Store {
    /// `id` and the sessions that started it, theirs in turn, nearest first (`parent`, else `startedBy`, else `origin`).
    /// It stops at a caller's mark (`Caller.marks`: started by kelpd's program or one Kelp couldn't place) or a session gone.
    func lineage(_ id: String) throws -> [Session] {
        var line: [Session] = [], next: String? = id
        while let n = next, !Caller.marks.contains(n), line.count < 32, !line.contains(where: { $0.id == n }),
            let s = try session(n)
        {
            line.append(s)
            next = s.parent ?? s.startedBy ?? s.origin.flatMap { Caller.session(of: $0) ?? $0 }
        }
        return line
    }

    /// Whether what `id` does is held to an agent's rules: an agent is on its line, or the line breaks off (it stops at a
    /// mark, `Caller.marks`, or at a session that's gone), which can't be told from an agent's.
    func forAnAgent(_ id: String) throws -> Bool {
        let line = try lineage(id)
        let cameFrom = line.last.flatMap { $0.parent ?? $0.startedBy ?? $0.origin }
        let typed = line.contains { Caller.typedOrigin($0.origin) }   // started by an agent the user typed in
        return line.contains(where: \.isAgent) || cameFrom != nil || typed
    }
}
