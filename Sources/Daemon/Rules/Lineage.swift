import Core
import Foundation

/// Who started whom, read from the records. The rules (`Daemon.allow`) and the caller lookup (`Callers`) both use it,
/// so they agree.
extension Store {
    /// Returns the session `id`, the session that started it, the one that started that, and so on, nearest first
    /// (`parent`, else `startedBy`, else `origin`). It stops at a caller's mark (`Caller.marks`: started by kelpd's
    /// program or by one Kelp couldn't place) or at a session that's gone.
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

    /// Returns who is asking, from the caller's origin (`Sessions.asker`). The outer nil means the user (Kelp's window,
    /// or one of the user's own terminals). Otherwise it is the agent's session to ask, or an inner nil when there is
    /// no session to ask (a program kelpd started, or a program that left its terminal).
    func agent(origin: String?) -> String?? {
        guard let origin else { return .none }
        let session = Caller.session(of: origin)
        // A session whose record can't be read is held to an agent's rules, the same way the fence treats it.
        if let session, !Caller.typedOrigin(origin),
            Log.store.attempt("whether \(session) is an agent's", { try forAnAgent(session) }) == false
        {
            return .none
        }
        return .some(session)
    }

    /// Whether what `id` does is held to an agent's rules. It is when an agent is in its lineage, or when the lineage
    /// breaks off (at a mark, `Caller.marks`, or at a session that's gone), because then it can't be told from an
    /// agent's. It is also held when its own record is gone. A caller is looked up once per connection
    /// (`Callers.caller`) and can outlive its session (a restart deletes the old session's record), and then who
    /// started that session can't be read any more.
    func forAnAgent(_ id: String) throws -> Bool {
        let line = try lineage(id)
        guard !line.isEmpty else { return true }
        let cameFrom = line.last.flatMap { $0.parent ?? $0.startedBy ?? $0.origin }
        let typed = line.contains { Caller.typedOrigin($0.origin) }   // started by an agent the user typed in
        return line.contains(where: \.isAgent) || cameFrom != nil || typed
    }
}
