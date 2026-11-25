import Core
import Foundation

/// Where a chat's work stands on the Agents Overview's board. The stage follows what the chat made, not what its agent
/// does now, so a card moves only forward: an agent asking is a mark on its card, not a column of its own. The one way
/// back is a chat that works again, as on a review comment: it is at work once more.
enum OverviewStage: Int, CaseIterable, Comparable {
    case working, review, pullRequest, done

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// What the stage is worked out from. `turnFiles` are the files the chat's last turn changed; `dirty` the files of
    /// its folder not committed yet.
    struct Facts {
        var status: AgentStatus
        var limited = false
        var pr: GitHub.PullRequest?
        var turnFiles: [String] = []
        var dirty: Set<String> = []
    }

    /// An ended chat is done. A live agent, one that asks or failed, or one a limit stopped, is at work. Otherwise its
    /// branch's pull request says (merged is done, open is in review on GitHub); then a turn whose files aren't
    /// committed waits for review, a turn whose files are is done, and a turn that changed nothing leaves the chat at
    /// work (it answered, or it rests).
    static func of(_ f: Facts) -> Self {
        if f.status == .exited { return .done }
        if [.working, .waiting, .error].contains(f.status) || f.limited { return .working }
        switch f.pr?.state {
        case "MERGED": return .done
        case "OPEN": return .pullRequest
        default: break
        }
        if f.turnFiles.isEmpty { return .working }
        return Set(f.turnFiles).isDisjoint(with: f.dirty) ? .done : .review
    }

    var title: String {
        switch self {
        case .working: String(localized: "In Progress")
        case .review: String(localized: "To Review")
        case .pullRequest: String(localized: "In PR")
        case .done: String(localized: "Done Today")
        }
    }
}
