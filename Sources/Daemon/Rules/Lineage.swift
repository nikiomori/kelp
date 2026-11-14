import Core
import Foundation

/// Who started whom, read from the records: the same for the rules (`Daemon.allow`) and for who a caller is (`Callers`).
extension Store {
    /// `id` and the sessions that started it, theirs in turn, nearest first (`parent`, else `startedBy`, else `origin`).
    /// It stops at a caller's mark (`Caller.marks`: started by kelpd's program or one Kelp couldn't place) or a session gone.
    func lineage(_ id: String) throws -> [Session] {
        var line: [Session] = [], next: String? = id
        while let current = next, !Caller.marks.contains(current), line.count < 32,
            !line.contains(where: { $0.id == current }), let session = try self.session(current)
        {
            line.append(session)
            next = session.parent ?? session.startedBy ?? session.origin.flatMap { Caller.session(of: $0) ?? $0 }
        }
        return line
    }

    /// Who asks, from the caller (`Sessions.asker`): nil for the user (Kelp's window, a terminal of the user's own);
    /// else the agent's session to ask, nil inside when there's none to ask (a program of kelpd's, one that left).
    func agent(origin: String?) -> String?? {
        guard let origin else { return .none }
        let session = Caller.session(of: origin)
        // A session that can't be read is held to an agent's rules, as the fence holds it.
        if let session, !Caller.typedOrigin(origin),
            Log.store.attempt("whether \(session) is an agent's", { try forAnAgent(session) }) == false
        {
            return .none
        }
        return .some(session)
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
