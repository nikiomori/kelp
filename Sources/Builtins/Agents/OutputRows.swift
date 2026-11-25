import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// ⌘P's lines of terminal output, under their own heading after its own matches. For what is typed (3 characters or
/// more), each open terminal or agent that printed it lately gives its newest line with it, and ↩ opens that one with
/// its find bar on the line.
@MainActor
enum OutputRows {
    static func section(_ app: AppModel) -> QuickSection {
        QuickSection("In Terminal Output") { await rows(app, $0) }
    }

    /// One row per session that printed `query`: its line, whose it is and where, and how many more lines have it.
    static func rows(_ app: AppModel, _ query: String) async -> [QuickItem] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 3 else { return [] }   // fewer match everything
        let open = app.sessions.filter { $0.status != .exited && $0.startedBy == nil }   // what ⌘P lists by name
        guard !open.isEmpty, let found = await app.quiet(SessionFind(ids: open.map(\.id), query: query)) else {
            return []
        }
        return found.compactMap { hit in
            guard let s = open.first(where: { $0.id == hit.id }) else { return nil }
            let worktree = app.worktree(s.worktreeId)
            let place = app.groupName(worktree) ?? app.projectName(worktree?.repoId)
            return QuickItem(
                hit.line, detail: [app.catalog.displayName(s), place].compactMap { $0 }.joined(separator: " · "),
                icon: "terminal", image: app.catalog.icon(s.agent, size: Metrics.iconMenu),
                note: hit.count > 1 ? String(localized: "\(hit.count - 1) more matches") : "", mono: true,
                open: { land(app, s, query, split: false) }, split: { land(app, s, query, split: true) })
        }
    }

    /// Shows the session (beside, in a split, for ⇧↩) with its find bar open on `query` at the newest match, the line
    /// the row showed.
    static func land(_ app: AppModel, _ s: Session, _ query: String, split: Bool) {
        let uri = TabURI.session(s.id)
        if split {
            app.workbench.open(uri, split: .right, workspace: s.worktreeId)
        } else {
            app.workbench.focus(session: s.id)
        }
        guard let tab = app.workbench.focusedContent as? SessionTab, tab.uri == uri else { return }
        tab.pane.findNewest(query)
    }
}
