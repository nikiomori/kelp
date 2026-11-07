import Core
import Foundation

/// How loud an agent's new state is (Settings › Agents › Notifications). A question or a failure comes however long the
/// turn took; a turn shorter than `quietUnder` finishes on its row alone.
struct NotifyRule: Equatable {
    enum Level: String { case off, banner, sound }
    var finished = Level.banner, waiting = Level.sound, failed = Level.sound
    var quietUnder: TimeInterval = 20

    /// `turn`: how long it worked; nil when that isn't known (Kelp just opened): a banner too many beats one missed.
    func level(_ status: AgentStatus, turn: TimeInterval?) -> Level {
        switch status {
        case .waiting: waiting
        case .error: failed
        case .done: (turn ?? .infinity) < quietUnder ? .off : finished
        default: .off
        }
    }

    /// Since it last started working. A question cuts a turn in two: what follows your answer counts from the answer.
    static func turn(_ s: Session, after old: Session?) -> TimeInterval? {
        guard let old, old.status == .working, let from = old.statusAt, let to = s.statusAt else { return nil }
        return to.timeIntervalSince(from)
    }
}

/// One reminder of a question that went unanswered (Settings › Agents › Notifications): no growing series of pings.
enum QuestionReminder {
    static func minutes(_ setting: String) -> Int? { Int(setting) }

    /// The question it was asked for still stands: not answered, not followed by another.
    static func stillStands(_ asked: Session, now: Session?) -> Bool {
        now?.status == .waiting && now?.statusAt == asked.statusAt
    }
}
