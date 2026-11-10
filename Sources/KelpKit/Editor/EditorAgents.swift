import AppKit
import Core
import WorkbenchKit

/// Following the sessions: tabs for those started elsewhere, gone for those that ended, a restarted one in its old tab.
extension EditorArea {
    /// Daemon state changed: sessions started elsewhere (CLI, agents, scripts) get a tab; deleted ones go.
    func reconcile() {
        let mine = app.sessions.filter { $0.worktreeId == workspaceId }
        let known = Set(app.sessions.map(\.id))
        var changed = false, movedOut = false
        for tab in layout.allTabs where TabURI.scheme(tab.uri) == "session" {
            let sid = TabURI.body(tab.uri)
            let session = app.session(sid)
            if let other = session?.worktreeId, other != workspaceId {   // gone to another screen: its tab goes with it
                contents[tab.id] = nil
                layout.remove(tab.id)
                changed = true
                movedOut = true
                continue
            }
            // Ended while Kelp was closed (or deleted): nothing to show. Ended now: keep it, the tab offers Restart.
            // A lost connection stays too: its agent still runs on the host, reached by Reconnect, ended by closing the tab.
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
        if movedOut, layout.allTabs.isEmpty { WorkspaceActions(app).closeEmpty(workspaceId, ended: nil) }
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
        if arrange() { changed = true }   // an agent started, paused, woke or ended: the panes follow
        if changed || (start == nil && layout.allTabs.isEmpty) || view.subviews.isEmpty {
            // Rebuilding the panes takes the keys from the terminal being typed in: they go back to the focused tab.
            let typing = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
            render()
            if typing { focusSelected() }
        } else {
            for gid in layout.root?.sessions ?? [] { refreshGroup(gid) }
        }
    }

    /// `new` in the tab that showed `old`, in its place (a restarted session, a new file saved under a name).
    /// `focus: false` for a workspace that isn't on screen.
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

    func focus(session sid: String) {
        if let tab = layout.tab(uri: TabURI.session(sid)) { select(tab.id) } else { open(TabURI.session(sid)) }
    }
}
