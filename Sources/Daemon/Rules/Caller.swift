import Foundation

/// Who a call came from, told by its process (`Callers.caller`). `Daemon.allow` decides from this what the call may do.
enum Caller: Hashable, Sendable {
    /// Outside every session: the user's own terminal, Kelp's window, the daemon itself. Not held to an agent's rules.
    case user
    /// A program in that session's process tree, or in its terminal. It is held to an agent's rules when an agent is in
    /// its process line, or once the session's record is gone (`forAnAgent`).
    case session(String)
    /// A program run under an agent that the user started by hand in that session's terminal (`claude` typed into a
    /// shell). It is held to an agent's rules as that session's agent, whatever the session is.
    case typedAgent(String)
    /// A program this daemon started (an extension's command or event, a repo's git hook, what they leave running), or
    /// a program on a connection that hung up. Whoever wrote it, it acts on no session and answers no question.
    case kelpd
    /// A caller that was gone before it could be looked at (it connected and ended at once, leaving the connection to a
    /// child). It is held to an agent's rules and speaks for no session.
    case unknown
    /// None of the above, and not a caller Kelp can tell is the user's (`Callers.session(running:)`): a program that
    /// left every terminal and app behind (a double fork with `setsid`, `script`, a tmux server nobody is attached to).
    /// It is held to an agent's rules.
    case detached

    /// The prefix a session records before the terminal's id (`typed:<id>`) when it was started under an agent the user
    /// typed in by hand. Its lineage then continues into that terminal's session (`lineage`), and it is held to an
    /// agent's rules (`forAnAgent`).
    static let typed = "typed:"

    /// Whether `origin` (or a `madeBy`) says it was started by an agent the user typed into `terminal`.
    static func started(_ origin: String?, byAgentTypedInto terminal: String) -> Bool { origin == typed + terminal }
    /// Whether `origin` says it was started by an agent the user typed into some terminal.
    static func typedOrigin(_ origin: String?) -> Bool { origin?.hasPrefix(typed) == true }

    /// Returns the session an origin (or a `madeBy`) names: the session's id, or the terminal's session for a `typed:`
    /// origin. Returns nil for a mark.
    static func session(of origin: String?) -> String? {
        guard let origin, !marks.contains(origin) else { return nil }
        return origin.hasPrefix(typed) ? String(origin.dropFirst(typed.count)) : origin
    }

    /// The marks that `origin` records for a caller with no session. A mark is never a session's id (a UUID), and a
    /// lineage stops at it.
    static let marks: Set<String> = [Callers.ownProgram, Callers.unknown, Callers.detached]

    /// What a session started by this caller records as its origin (`Session.origin`): the caller's session, or a mark
    /// (`marks`) where the lineage stops. `Store.forAnAgent` holds a lineage that ends in a mark to an agent's rules.
    var origin: String? {
        switch self {
        case .user: nil
        case .session(let id): id
        case .typedAgent(let id): Self.typed + id
        case .kelpd: Callers.ownProgram
        case .unknown: Callers.unknown
        case .detached: Callers.detached
        }
    }
}
