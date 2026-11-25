import AppKit
import Core
import WorkbenchKit

/// ⇧⌘U: the next agent that needs you, or when none does, back to the agent you last prompted.
@MainActor
extension Workbench {
    /// Shows where ⇧⌘U goes (`needingYouTarget`), or beeps when there is nowhere to go.
    package func showNextNeedingAttention() {
        guard let target = needingYouTarget() else {
            NSSound.beep()
            return
        }
        focus(session: target.session.id)
    }

    /// Returns the next agent that asked something or finished, after the one in front. When none waits, it is the
    /// agent last prompted (`back`), unless that one is in front, ended, or in a group put away. Nil means nowhere.
    func needingYouTarget() -> (session: Session, back: Bool)? {
        let current = editor?.layout.focusedGroup?.selectedTab.map(\.uri).flatMap {
            TabURI.scheme($0) == "session" ? TabURI.body($0) : nil
        }
        let queue = AttentionQueue(app).sessions
        guard queue.isEmpty else { return AttentionQueue.next(in: queue, after: current).map { ($0, false) } }
        guard let last = lastPrompted.flatMap(app.session), last.id != current, last.status != .exited,
            app.worktree(last.worktreeId).map({ !$0.archived }) == true
        else { return nil }
        return (last, true)
    }

    /// The title of ⇧⌘U's menu item, which names the agent it goes back to when none needs you, as Undo names what
    /// it undoes.
    var needingYouTitle: String {
        guard let target = needingYouTarget(), target.back else { return String(localized: "Show Agent Needing You") }
        let name = app.catalog.displayName(target.session)
        guard let project = app.repo(app.worktree(target.session.worktreeId)?.repoId)?.name else {
            return String(localized: "Back to \(name)")
        }
        return String(localized: "Back to \(name) · \(project)")
    }

    /// Notes a prompt (`lastPrompted`): an agent's turn that began while its tab had the focus.
    func noteTurn(_ session: Session, was old: Session?) {
        if Self.turnBegan(session, was: old), isViewing(session: session.id) { lastPrompted = session.id }
    }

    /// Whether a chat's agent went to work from another state. A session first heard of already working was started
    /// elsewhere (by another agent), not prompted here.
    static func turnBegan(_ session: Session, was old: Session?) -> Bool {
        guard let old, session.isChat, session.isAgent else { return false }
        return session.status == .working && old.status != .working
    }
}
