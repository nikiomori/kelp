import AppKit
import Core

/// How full an agent's plan is, said beside it where agents are chosen: the start tiles' bar (`used`, 0…1) and the
/// short `amount` under it with its `tip`, the "+" menu's `text`; all in `color`.
package typealias AgentNote = (used: Double, amount: String, text: String, tip: String?, color: NSColor)

/// What the plan limits say where the shell shows agents, from the built-in that reads them (Agents'). The words are
/// the built-in's; the shell only has places for them.
package struct PlanWords {
    /// Beside each agent where agents are chosen, by agent id.
    let notes: @MainActor () -> [String: AgentNote]
    /// Under the first-task field when the agent it starts (`agent`, called `name`) is nearly out; `instead`: the one of
    /// `others` with the most room, offered in its place.
    let warning: @MainActor (_ agent: String, _ name: String, _ others: [String]) -> (text: String, instead: String?)?
    /// Of a session a plan limit stopped, or that goes on at the reset: its row's second line ("Limit:", "resets 3pm").
    let rowLine: @MainActor (Session) -> (word: String, text: String)?
    /// Its title where it's listed under the chat that started it: "Claude Code hit its 5-hour limit".
    let title: @MainActor (_ name: String, Session) -> String
    /// Its notification's text: "5-hour · resets 3:40pm".
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
