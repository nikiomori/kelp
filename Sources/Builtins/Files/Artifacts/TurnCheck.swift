import Core
import Foundation
import KelpKit

/// After each turn of the page's agent, Kelp checks the page as it drew it again and, when the turn brought issues
/// that weren't there before it, tells the agent once, as Open Design's lint on save does: the agent fixes them before
/// the user has looked. A turn Kelp's own message started is not checked again, so the two never ping-pong. Only what
/// is new this turn, once; the user sees all of it in Check as before.
@MainActor
final class TurnCheck {
    /// The issues there before the turn, and those already told.
    private var before: Set<String> = [], told: Set<String> = []
    private var working = false, ended = false, ours = false, oursRunning = false

    /// The page's agent started or ended a turn.
    func agent(working now: Bool, issues: [String]?) {
        if now, !working {
            before = Set(issues ?? [])
            oursRunning = ours
            ours = false
            ended = false
        } else if !now, working {
            ended = true
        }
        working = now
    }

    /// The page was checked: the lines to tell the agent, if this is the check after its turn and it found new ones.
    func checked(_ issues: [String]) -> [String] {
        guard ended else { return [] }
        ended = false
        if oursRunning {
            oursRunning = false
            return []
        }
        let new = issues.filter { !before.contains($0) && !told.contains($0) }
        told.formUnion(new)
        ours = !new.isEmpty
        return new
    }

    /// What Kelp writes to the agent about `issues` on `page`.
    static func message(_ issues: [String], page: String) -> String {
        (["Kelp checked \(page) after your turn: \(issues.count) new issue\(issues.count == 1 ? "" : "s")."]
            + issues.map { "- " + $0 } + ["Fix these in the page, or say why not."]).joined(separator: "\n")
    }
}
