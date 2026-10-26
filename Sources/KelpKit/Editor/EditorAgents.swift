import AppKit
import Core
import WorkbenchKit

/// Starting agents and terminals in the focused pane, and reacting to their sessions.
extension EditorArea {
    /// `draft`: the prompt is typed for the user to send, not sent.
    package func newAgent(_ agent: String? = nil, prompt: String? = nil, draft: Bool = false, split: SplitDirection? = nil) {
        createSession(SessionCreate(worktreeId: workspaceId, agent: agent ?? app.catalog.defaultAgent, prompt: prompt?.isEmpty == false ? prompt : nil,
                                    draft: draft ? true : nil), split: split)
    }
    package func newTerminal(split: SplitDirection? = nil) { createSession(SessionCreate(worktreeId: workspaceId, agent: "shell"), split: split) }
    /// A terminal attached to tmux session `name` (started if tmux has none); the tab already attached to it, if there is one.
    func newTmux(_ name: String, split: SplitDirection? = nil) {
        let name = Tmux.name(name)
        if let s = app.sessions.first(where: { $0.worktreeId == workspaceId && $0.status != .exited && Tmux.session($0.argv) == name }) {
            open(TabURI.session(s.id), split: split); return
        }
        createSession(SessionCreate(worktreeId: workspaceId, tmux: name), split: split)
    }
    /// `cwd`: run it in another folder (a remote project's runs on its host), as a tab here. `created`: its session.
    package func run(command: String?, title: String? = nil, cwd: String? = nil, split: SplitDirection? = nil, created: ((Session) -> Void)? = nil) {
        guard let command, !command.isEmpty else { newTerminal(split: split); return }
        createSession(SessionCreate(cwd: cwd, worktreeId: workspaceId, command: command, title: title), split: split, created: created)
    }

    private func createSession(_ p: SessionCreate, split: SplitDirection?, created: ((Session) -> Void)? = nil) {
        var p = p
        if let (cols, rows) = terminalSize(split: split) { p.cols = cols; p.rows = rows }
        Task {
            guard let s = await app.call(p) else { return }
            app.upsert(s)
            created?(s)
            open(TabURI.session(s.id), split: split)
        }
    }

    /// The size the new terminal will have, so the shell's first screen isn't drawn for another width (zsh's stray "%"
    /// line, an agent's banner wrapped twice). A split gets half; a guess on the small side only leaves room.
    private func terminalSize(split: SplitDirection?) -> (Int, Int)? {
        guard let g = focusedContent?.terminalGrid ?? contents.values.lazy.compactMap(\.terminalGrid).first ?? app.workbench.terminalGrid else { return nil }
        switch split {
        case .right?: return (max(20, g.cols / 2 - 1), g.rows)
        case .down?: return (g.cols, max(5, g.rows / 2 - 1))
        case nil: return (g.cols, g.rows)
        }
    }

    /// Daemon state changed: sessions started elsewhere (CLI, agents, scripts) get a tab; deleted ones go.
    func reconcile() {
        let mine = app.sessions.filter { $0.worktreeId == workspaceId }
        let known = Set(app.sessions.map(\.id))
        var changed = false
        for t in layout.allTabs where TabURI.scheme(t.uri) == "session" {
            let sid = TabURI.body(t.uri)
            let s = app.session(sid)
            // Ended while Kelp was closed (or deleted): nothing to show. Ended now: keep it, the tab offers Restart.
            // A lost connection stays too: its agent still runs on the host, reached by Reconnect, ended by closing the tab.
            if !known.contains(sid) || (!reconciledOnce && s?.status == .exited && s?.connectionLost != true) {
                contents[t.id] = nil
                layout.remove(t.id)
                changed = true
            }
        }
        if layout.allTabs.isEmpty, layout.root != nil {
            let manual = layout.manual
            layout = WorkspaceLayout()
            layout.manual = manual
            changed = true
        }
        let shown = Set(layout.allTabs.filter { TabURI.scheme($0.uri) == "session" }.map { TabURI.body($0.uri) })
        closed = closed.filter { app.session($0).map { $0.status != .exited } ?? false }
        for s in mine where s.status != .exited && !shown.contains(s.id) && !closed.contains(s.id) {
            layout.add(TabURI.session(s.id)); changed = true
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
    package func replace(_ old: String, with new: String, focus: Bool = true) {
        guard let t = layout.replace(old, with: new) else { open(new, focus: focus); return }
        contents[t.id] = nil
        render(); select(t.id, focus: focus)
    }

    func focus(session sid: String) {
        if let t = layout.tab(uri: TabURI.session(sid)) { select(t.id) } else { open(TabURI.session(sid)) }
    }
}
