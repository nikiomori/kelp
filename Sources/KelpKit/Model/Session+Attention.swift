import AppKit
import Core
import DesignKit

extension Session {
    /// The status the session's mark shows. A terminal or a command (not an agent) shows as working while a program
    /// in it reports how far it got.
    package var markStatus: AgentStatus {
        progress != nil && !isAgent ? .working : status
    }
    /// The status the mark on the session's row shows. A paused agent's row is dimmed, but a finished result you
    /// haven't read keeps its bright mark.
    package var shownStatus: AgentStatus { status == .paused && unread ? .done : markStatus }
    /// The status in words, such as "Working · 40 %" when the session says how far it got.
    /// A session whose connection to its host dropped says so, because "Ended" would read as finished.
    package var statusWords: String {
        if connectionLost { return String(localized: "Connection lost") }
        let shown = markStatus
        return shown == .working ? progress.map { "\(shown.words) · \($0) %" } ?? shown.words : shown.words
    }
    /// "Works in .claude/worktrees/fix-login" when the agent went out of the folder it started in.
    package var workingElsewhere: String? {
        guard let dir = workDir else { return nil }
        let inside = Paths.relative(dir, to: cwd) ?? (dir as NSString).abbreviatingWithTildeInPath
        return String(localized: "Works in \(inside)")
    }
}

/// Agents waiting for the user, in the order to visit them: questions and failures before finished work, oldest first.
@MainActor
struct AttentionQueue {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    var sessions: [Session] {
        app.sessions
            .filter(\.wantsYou)   // what the summary counts, including a paused agent's unread result
            .filter { $0.parent == nil || $0.shownStatus != .done }   // a child's result goes to its parent, not you
            .filter { app.worktree($0.worktreeId).map { !$0.archived } == true }   // in a workspace on the sidebar (an archived one isn't loaded)
            .sorted { Self.order($0) < Self.order($1) }
    }

    /// Sorts finished results last, and the rest oldest first.
    private static func order(_ session: Session) -> (Int, Date) {
        (session.shownStatus == .done ? 1 : 0, session.statusAt ?? session.createdAt)
    }

    /// Returns the session after `current` (wrapping), so pressing again walks the whole queue.
    func next(after current: String?) -> Session? { Self.next(in: sessions, after: current) }

    /// Returns the session after `current` in `queue` (wrapping). It is the first one when `current` isn't in the
    /// queue, and nil when `current` is alone there.
    static func next(in queue: [Session], after current: String?) -> Session? {
        guard let index = queue.firstIndex(where: { $0.id == current }) else { return queue.first }
        return queue.count > 1 ? queue[(index + 1) % queue.count] : nil
    }
}

extension Session {
    /// Returns a row's second line. It is what the row's own agent asks, or else what one of its children asks, under
    /// that child's name. `children` holds the agents it started and the ones they started (`AppModel.children(of:)`).
    /// `back` is why a parked agent came back (`Arrangement.parkedBack`), shown when nothing more urgent is. `plans`
    /// gives the words for a plan limit that stopped an agent (`Contributions.plans`).
    @MainActor func rowLine(
        mode: String, children: [Session], back: String? = nil, plans: PlanWords? = nil
    ) -> (prefix: (String, NSColor)?, text: String)? {
        let own = askLine(mode: mode, plans: plans)
        guard own?.prefix == nil else { return own }
        if let back { return ((String(localized: "Back:"), .secondaryLabelColor), back) }
        for child in children {
            if let line = child.askLine(mode: mode, plans: plans), let color = line.prefix?.1 {
                return ((child.displayTitle + ":", color), line.text)
            }
        }
        return own
    }
}

/// What an agent's row says about the agent's state, for the sidebar and for everything that counts the same way.
extension Session {
    /// Returns the second line on an agent's row, or nil for none. It is "Limit: resets 3:40 PM" when a plan limit
    /// stopped the agent. For an agent that needs you, it is what the agent wants in its own words (its summary), such
    /// as "Asks: may I run npm test?" or "Failed: rate limit until 14:00". With `always`, every agent says what it is
    /// working on.
    @MainActor func askLine(mode: String, plans: PlanWords? = nil) -> (prefix: (String, NSColor)?, text: String)? {
        let st = shownStatus, text = summary.isEmpty ? statusWords : summary
        if mode != "never", let limit = plans?.rowLine(self) { return ((limit.word, .textOrange), limit.text) }
        switch (mode, st) {
        case ("never", _): return nil
        case (_, .waiting): return ((String(localized: "Asks:"), .textOrange), text)
        case (_, .error): return ((String(localized: "Failed:"), .textRed), text)
        case ("always", _): return (nil, text)
        default: return nil
        }
    }

    /// Whether the chat is asking for you, has failed, or has finished and you haven't looked yet.
    var wantsYou: Bool {
        let st = shownStatus
        return isChat && (st == .waiting || st == .error || (st == .done && unread))
    }

    /// Whether there is something to look at: finished or asking, and not opened since (shown bold, like unread mail).
    var isNews: Bool { unread && [.done, .waiting, .error].contains(shownStatus) }
}
