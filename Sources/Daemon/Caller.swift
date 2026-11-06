import Foundation

/// Who a call came from, by its process (`Sessions.caller`): what it may do is `Daemon.allow`'s, by this.
enum Caller: Hashable, Sendable {
    /// Outside every session: the user's own terminal, Kelp's window, the daemon itself. Not held to an agent's rules.
    case user
    /// A program in that session's process tree, or its terminal: held to an agent's rules when an agent is on its line.
    case session(String)
    /// A program this daemon started (an extension's command or event, a repo's git hook, what they leave running), or
    /// one on a connection that hung up: whoever wrote it, it acts on no session and answers no question.
    case kelpd
    /// Gone before it could be looked at (it connected and ended at once, leaving the connection to a child): held to an
    /// agent's rules, but for a state with no words (a hook may send one and end).
    case unknown
    /// One that left its parent and its terminal both (a double fork and `setsid`): held to an agent's rules.
    case detached

    /// What a session it starts records as its origin (`Session.origin`): its session, or a mark whose line breaks off,
    /// which `Sessions.forAnAgent` holds to an agent's rules.
    var origin: String? {
        switch self {
        case .user: nil
        case .session(let id): id
        case .kelpd: Sessions.ownProgram
        case .unknown: Sessions.unknown
        case .detached: Sessions.detached
        }
    }
}
