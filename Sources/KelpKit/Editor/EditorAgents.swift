import AppKit
import Core
import WorkbenchKit

/// How the editor area follows the sessions: it opens tabs for sessions started elsewhere, removes tabs of sessions
/// that ended, and puts a restarted session in its old tab.
extension EditorArea {
    /// Runs when the daemon's state changed. Sessions started elsewhere (CLI, agents, scripts) get a tab, and the tabs
    /// of deleted sessions go.
    func reconcile() {
        let mine = app.sessions.filter { $0.worktreeId == workspaceId }
        let known = Set(app.sessions.map(\.id))
        var changed = false, movedOut = false
        for tab in layout.allTabs where TabURI.scheme(tab.uri) == "session" {
            let sid = TabURI.body(tab.uri)
            let session = app.session(sid)
            if let other = session?.worktreeId, other != workspaceId {   // moved to another workspace, so its tab goes
                contents[tab.id] = nil
                layout.remove(tab.id)
                changed = true
                movedOut = true
                continue
            }
            // A session that ended while Kelp was closed (or was deleted) has nothing to show. One that ends now keeps
            // its tab, which offers Restart. A lost connection keeps its tab too, because its agent still runs on the
            // host; Reconnect reaches it, and closing the tab ends it.
            if !known.contains(sid)
                || (!reconciledOnce && session?.status == .exited && session?.connectionLost != true)
            {
                contents[tab.id] = nil
                layout.remove(tab.id)
                changed = true
            }
        }
        if layout.allTabs.isEmpty, layout.root != nil {
            let manual = layout.manual
            layout = WorkspaceLayout()
            layout.manual = manual
            changed = true
        }
        if movedOut, layout.allTabs.isEmpty { WorkspaceActions(app).emptied(workspaceId) }
        let shown = Set(layout.allTabs.filter { TabURI.scheme($0.uri) == "session" }.map { TabURI.body($0.uri) })
        closed = closed.filter { app.session($0).map { $0.status != .exited } ?? false }
        for session in mine
        where session.status != .exited && !shown.contains(session.id) && !closed.contains(session.id)
            && !app.workbench.isHidden(session.id)
        {
            layout.add(TabURI.session(session.id), select: false)
            changed = true
        }
        reconciledOnce = true
        if arrange() { changed = true }   // when an agent started, paused, woke or ended, the panes follow
        if changed || (start == nil && layout.allTabs.isEmpty) || view.subviews.isEmpty {
            // Rebuilding the panes takes the keys from the terminal being typed in, so give them back to the focused
            // tab.
            let typing = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
            render()
            if typing { focusSelected() }
        } else {
            for gid in layout.root?.sessions ?? [] { refreshGroup(gid) }
        }
    }

    /// Shows `new` in the tab that showed `old`, in the same place (a restarted session, a new file saved under a
    /// name). Pass `focus: false` for a workspace that isn't on screen.
    func replace(_ old: String, with new: String, focus: Bool = true) {
        let dup = layout.tab(uri: new)
        guard let tab = layout.replace(old, with: new) else {
            open(new, focus: focus)
            return
        }
        contents[tab.id] = nil
        if let dup { contents[dup.id] = nil }
        render()
        select(tab.id, focus: focus)
    }

    /// Follow Edits: shows `uri` beside the tab of `owner` and leaves the keys where they are. The file takes the place
    /// of `last`, the file shown before for the same agent, while that one is open and unedited, so following leaves
    /// one tab rather than one tab per file.
    func showBeside(_ uri: String, of owner: String, replacing last: String?) {
        let typing = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        let keep = layout.focused
        if let last, last != uri, layout.tab(uri: uri) == nil, let tab = layout.tab(uri: last),
            contents[tab.id]?.isEdited != true
        {
            replace(last, with: uri, focus: false)
        } else if layout.tab(uri: uri) == nil, let mine = layout.tab(uri: owner), let gid = layout.group(of: mine.id) {
            let target = layout.groups.keys.sorted().first { $0 != gid } ?? layout.newGroup(beside: gid, vertical: true)
            layout.add(uri, to: target)
        } else {
            showAside(uri)   // already open, so it is brought forward where it is
            return
        }
        layout.focused = keep
        arrange()   // with agents side by side, files go to the pane the agents share
        render()
        if typing { focusSelected() }
    }

    func focus(session sid: String) {
        if let tab = layout.tab(uri: TabURI.session(sid)) { select(tab.id) } else { open(TabURI.session(sid)) }
    }
}
