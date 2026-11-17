import AppKit
import Core

/// How full an agent's plan is, shown beside the agent where agents are chosen: the bar on the start tiles (`used`,
/// 0…1) with the short `amount` and its `tip` under it, and the `text` in the "+" menu. All of them use `color`.
package typealias AgentNote = (used: Double, amount: String, text: String, tip: String?, color: NSColor)

/// What the plan limits say where the shell shows agents, supplied by the built-in that reads the limits (Agents). The
/// words are the built-in's; the shell only has places for them.
package struct PlanWords {
    /// The note beside each agent where agents are chosen, keyed by agent id.
    let notes: @MainActor () -> [String: AgentNote]
    /// The warning under the first-task field when the agent it starts (`agent`, called `name`) is nearly out.
    /// `instead` is the agent among `others` with the most room left, offered in its place.
    let warning: @MainActor (_ agent: String, _ name: String, _ others: [String]) -> (text: String, instead: String?)?
    /// The second line on the row of a session that a plan limit stopped, or that goes on at the reset ("Limit:",
    /// "resets 3pm").
    let rowLine: @MainActor (Session) -> (word: String, text: String)?
    /// The session's title where it's listed under the chat that started it: "Claude Code hit its 5-hour limit".
    let title: @MainActor (_ name: String, Session) -> String
    /// The text of its notification, such as "5-hour · resets 3:40pm".
    let banner: @MainActor (LimitHit) -> String

    package init(
        notes: @escaping @MainActor () -> [String: AgentNote],
        warning: @escaping @MainActor (String, String, [String]) -> (text: String, instead: String?)?,
        rowLine: @escaping @MainActor (Session) -> (word: String, text: String)?,
        title: @escaping @MainActor (String, Session) -> String,
        banner: @escaping @MainActor (LimitHit) -> String
    ) {
        self.notes = notes
        self.warning = warning
        self.rowLine = rowLine
        self.title = title
        self.banner = banner
    }
}
