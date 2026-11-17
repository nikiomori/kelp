import Core
import Foundation

/// How loudly Kelp tells you an agent's new status (Settings › Agents › Notifications). A question or a failure is told
/// however long the turn took; a finished turn shorter than `quietUnder` shows on its row only.
struct NotifyRule: Equatable {
    enum Level: String { case off, banner, sound }
    var finished = Level.banner, waiting = Level.sound, failed = Level.sound
    var quietUnder: TimeInterval = 20

    /// Returns the level for a status. `turn` is how long the agent worked, or nil when that isn't known (Kelp just
    /// opened); an unknown turn counts as long, because a banner too many beats one missed.
    func level(_ status: AgentStatus, turn: TimeInterval?) -> Level {
        switch status {
        case .waiting: waiting
        case .error: failed
        case .done: (turn ?? .infinity) < quietUnder ? .off : finished
        default: .off
        }
    }

    /// Returns how long the agent worked since it last started. A question cuts a turn in two, so the work after your
    /// answer counts from the answer.
    static func turn(_ session: Session, after old: Session?) -> TimeInterval? {
        guard let old, old.status == .working, let from = old.statusAt, let to = session.statusAt else { return nil }
        return to.timeIntervalSince(from)
    }
}

/// The single reminder of a question that went unanswered (Settings › Agents › Notifications), instead of a growing
/// series of pings.
enum QuestionReminder {
    /// Whether the question the reminder was set for still stands: it isn't answered and no other question followed.
    static func stillStands(_ asked: Session, now: Session?) -> Bool {
        now?.status == .waiting && now?.statusAt == asked.statusAt
    }
}
