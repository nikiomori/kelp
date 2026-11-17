import AppKit
import Core
import DesignKit

extension Session {
    /// What its mark shows: a terminal or a command (not an agent) works while a program in it shows how far it got.
    package var markStatus: AgentStatus {
        progress != nil && !isAgent ? .working : status
    }
    /// What its row's mark shows: a paused agent's row is dimmed, but what it finished and you haven't read keeps its
    /// bright mark.
    package var shownStatus: AgentStatus { status == .paused && unread ? .done : markStatus }
    /// "Working · 40 %" when it says how far it got.
    /// One whose connection to its host dropped says so, where "Ended" would read as finished.
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
            .filter(\.wantsYou)   // what the summary counts, a paused agent's unread result too
            .filter { $0.parent == nil || $0.shownStatus != .done }   // a child's result goes to its parent, not you
            .filter { app.worktree($0.worktreeId).map { !$0.archived } == true }   // in a workspace on the sidebar (an archived one isn't loaded)
            .sorted { Self.order($0) < Self.order($1) }
    }

    /// Results last, then oldest first.
    private static func order(_ session: Session) -> (Int, Date) {
        (session.shownStatus == .done ? 1 : 0, session.statusAt ?? session.createdAt)
    }

    /// The one after `current` (wrapping), so pressing again walks the whole queue.
    func next(after current: String?) -> Session? { Self.next(in: sessions, after: current) }

    /// The one after `current` in `queue` (wrapping); the first when `current` isn't in it, nil when it's alone there.
    static func next(in queue: [Session], after current: String?) -> Session? {
        guard let index = queue.firstIndex(where: { $0.id == current }) else { return queue.first }
        return queue.count > 1 ? queue[(index + 1) % queue.count] : nil
    }
}

extension Session {
    /// A row's second line: what the row's own agent asks, or else what one of its children asks (`children`: the
    /// agents it started and theirs, `AppModel.children(of:)`), under that child's name.
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

/// What an agent's row says of its state, for the sidebar and everyone who counts like it.
extension Session {
    /// The second line on an agent's row, or nil for none. "Limit: resets 3:40 PM" when a plan limit stopped it. For an
    /// agent that needs you, what it wants in its own words (its summary): "Asks: may I run npm test?", "Failed: rate
    /// limit until 14:00". With `always`, every agent says what it is working on.
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

    /// Asks for you, failed, or finished and not looked at yet.
    var wantsYou: Bool {
        let st = shownStatus
        return isChat && (st == .waiting || st == .error || (st == .done && unread))
    }

    /// Something to look at: finished or asking, and not opened since (bold, like unread mail).
    var isNews: Bool { unread && [.done, .waiting, .error].contains(shownStatus) }
}
