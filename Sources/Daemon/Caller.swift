import Foundation

/// Who a call came from, by its process (`Callers.caller`): what it may do is `Daemon.allow`'s, by this.
enum Caller: Hashable, Sendable {
    /// Outside every session: the user's own terminal, Kelp's window, the daemon itself. Not held to an agent's rules.
    case user
    /// A program in that session's process tree, or its terminal: held to an agent's rules when an agent is on its line.
    case session(String)
    /// A program run under an agent the user started by hand in that session's terminal (`claude` typed into a shell):
    /// held to an agent's rules as that session's, whatever the session is.
    case typedAgent(String)
    /// A program this daemon started (an extension's command or event, a repo's git hook, what they leave running), or
    /// one on a connection that hung up: whoever wrote it, it acts on no session and answers no question.
    case kelpd
    /// Gone before it could be looked at (it connected and ended at once, leaving the connection to a child): held to an
    /// agent's rules, and speaks for no session.
    case unknown
    /// None of the above and not the user's that Kelp can tell (`Callers.session(running:)`): one that left every
    /// terminal and app behind (a double fork with `setsid`, `script`, a tmux server nobody's attached to). Held to an
    /// agent's rules.
    case detached

    /// What a session started under an agent typed in by hand records before the terminal's id (`typed:<id>`): its line
    /// goes on to that terminal's session (`lineage`), and is held to an agent's rules (`forAnAgent`).
    static let typed = "typed:"

    /// Whether `origin` (or a `madeBy`) is what an agent typed into `terminal` started.
    static func started(_ origin: String?, byAgentTypedInto terminal: String) -> Bool { origin == typed + terminal }
    /// Whether `origin` is what an agent typed into some terminal started.
    static func typedOrigin(_ origin: String?) -> Bool { origin?.hasPrefix(typed) == true }

    /// The session an origin (or a `madeBy`) names: a session's id, or the terminal's of a `typed:` one; nil for a mark.
    static func session(of origin: String?) -> String? {
        guard let origin, !marks.contains(origin) else { return nil }
        return origin.hasPrefix(typed) ? String(origin.dropFirst(typed.count)) : origin
    }

    /// The marks `origin` records for a caller with no session: never a session's id (a UUID), and where a line stops.
    static let marks: Set<String> = [Sessions.ownProgram, Sessions.unknown, Sessions.detached]

    /// What a session it starts records as its origin (`Session.origin`): its session, or a mark (`marks`) where its
    /// line stops, which `Sessions.forAnAgent` holds to an agent's rules.
    var origin: String? {
        switch self {
        case .user: nil
        case .session(let id): id
        case .typedAgent(let id): Self.typed + id
        case .kelpd: Sessions.ownProgram
        case .unknown: Sessions.unknown
        case .detached: Sessions.detached
        }
    }
}
