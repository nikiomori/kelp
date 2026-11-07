import AppKit
import Core
import WorkbenchKit

/// Starting agents and terminals in the focused pane, and reacting to their sessions.
extension EditorArea {
    /// `draft`: the prompt is typed for the user to send, not sent.
    package func newAgent(
        _ agent: String? = nil, prompt: String? = nil, draft: Bool = false, split: SplitDirection? = nil,
        focus: Bool = true
    ) {
        createSession(
            SessionCreate(
                worktreeId: workspaceId, agent: agent ?? app.catalog.defaultAgent,
                prompt: prompt?.isEmpty == false ? prompt : nil,
                draft: draft ? true : nil), split: split, focus: focus)
    }
    package func newTerminal(split: SplitDirection? = nil, focus: Bool = true) {
        createSession(SessionCreate(worktreeId: workspaceId, agent: "shell"), split: split, focus: focus)
    }
    /// A terminal attached to tmux session `name` (started if tmux has none); the tab already attached to it, if there is one.
    func newTmux(_ name: String, split: SplitDirection? = nil, focus: Bool = true) {
        let name = Tmux.name(name)
        if let session = app.sessions.first(where: {
            $0.worktreeId == workspaceId && $0.status != .exited && Tmux.session($0.argv) == name
        }) {
            show(TabURI.session(session.id), split: split, focus: focus)
            return
        }
        createSession(SessionCreate(worktreeId: workspaceId, tmux: name), split: split, focus: focus)
    }
    /// `cwd`: run it in another folder (a remote project's runs on its host), as a tab here. `created`: its session.
    package func run(
        command: String?, title: String? = nil, cwd: String? = nil, split: SplitDirection? = nil, focus: Bool = true,
        created: ((Session) -> Void)? = nil
    ) {
        guard let command, !command.isEmpty else {
            newTerminal(split: split, focus: focus)
            return
        }
        createSession(
            SessionCreate(cwd: cwd, worktreeId: workspaceId, command: command, title: title), split: split,
            focus: focus, created: created)
    }

    /// A new shell where `old` was, in the tab left for it; attached again when `old` was tmux's.
    func newShell(like old: Session, inTabOf uri: String) {
        var create = SessionCreate(cwd: old.cwd, worktreeId: workspaceId, agent: "shell", tmux: Tmux.session(old.argv))
        if let (cols, rows) = terminalSize(split: nil) {
            create.cols = cols
            create.rows = rows
        }
        Task {
            guard let shell = await app.call(create) else { return }
            app.upsert(shell)
            replace(uri, with: TabURI.session(shell.id))
        }
    }

    /// In front of you, or (`focus` false, an agent or a script asked) beside what you're doing.
    private func show(_ uri: String, split: SplitDirection?, focus: Bool) {
        if focus { open(uri, split: split) } else { showAside(uri, split: split) }
    }

    private func createSession(
        _ create: SessionCreate, split: SplitDirection?, focus: Bool = true, created: ((Session) -> Void)? = nil
    ) {
        var create = create
        if let (cols, rows) = terminalSize(split: split) {
            create.cols = cols
            create.rows = rows
        }
        Task {
            guard let session = await app.call(create) else { return }
            app.upsert(session)
            created?(session)
            show(TabURI.session(session.id), split: split, focus: focus)
        }
    }

    /// The size the new terminal will have, so the shell's first screen isn't drawn for another width (zsh's stray "%"
    /// line, an agent's banner wrapped twice). A split gets half; a guess on the small side only leaves room.
    private func terminalSize(split: SplitDirection?) -> (Int, Int)? {
        guard
            let grid = focusedContent?.terminalGrid ?? contents.values.lazy.compactMap(\.terminalGrid).first
                ?? app.workbench.terminalGrid
        else { return nil }
        switch split {
        case .right?: return (max(20, grid.cols / 2 - 1), grid.rows)
        case .down?: return (grid.cols, max(5, grid.rows / 2 - 1))
        case nil: return (grid.cols, grid.rows)
        }
    }

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
            && !app.scripts.isHidden(session.id)
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
    package func replace(_ old: String, with new: String, focus: Bool = true) {
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
