import AppKit
import Core
import WorkbenchKit

/// Starts agents and terminals in a workspace's editor area, each in a tab there. It asks the daemon for the session at
/// the size its terminal will have, then shows the tab in front of you or beside what you're doing. Built-ins get a
/// starter for the workspace on screen (`Workbench.starter`), never the editor area itself.
@MainActor
package struct SessionStarter {
    let area: EditorArea
    private var app: AppModel { area.app }
    private var workspaceId: String { area.workspaceId }

    /// Starts an agent. With `draft`, the prompt is typed in for the user to send, not sent. `env` and `args` go on top
    /// of the agent's own (an extension's `session` action).
    package func newAgent(
        _ agent: String? = nil, prompt: String? = nil, draft: Bool = false, split: SplitDirection? = nil,
        focus: Bool = true, model: String? = nil, env: [String: String]? = nil, args: [String]? = nil
    ) {
        var create = SessionCreate(
            worktreeId: workspaceId, agent: agent ?? app.catalog.defaultAgent(in: area.worktree),
            model: model?.isEmpty == false ? model : nil, prompt: prompt?.isEmpty == false ? prompt : nil,
            draft: draft ? true : nil)
        (create.env, create.args) = (env, args)
        createSession(create, split: split, focus: focus)
    }
    package func newTerminal(split: SplitDirection? = nil, focus: Bool = true) {
        createSession(SessionCreate(worktreeId: workspaceId, agent: Session.shellAgent), split: split, focus: focus)
    }
    func splitTerminal(_ direction: SplitDirection) {
        guard let pane = area.layout.focusedGroup, pane.selectedTab != nil else { return newTerminal() }
        area.arrangedByHand()   // The new session can reach the workspace before the launch reply.
        createSession(
            SessionCreate(worktreeId: workspaceId, agent: Session.shellAgent), split: direction, beside: pane.id)
    }
    /// Opens a terminal attached to tmux session `name`, which is started if tmux has none. If a tab is already
    /// attached to it, that tab is shown instead.
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
    /// Runs a command in a tab here. `cwd` runs it in another folder (a remote project's command runs on its host).
    /// `created` receives the new session.
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

    /// Starts a new shell in the tab `old` left behind. When `old` was attached to tmux, the shell attaches again.
    func newShell(like old: Session, inTabOf uri: String) {
        let create = sized(
            SessionCreate(
                cwd: old.cwd, worktreeId: workspaceId, agent: Session.shellAgent, tmux: Tmux.session(old.argv)))
        let app = app, area = area
        Task {
            guard let shell = await app.call(create) else { return }
            app.upsert(shell)
            area.replace(uri, with: TabURI.session(shell.id))
        }
    }

    /// Shows the tab in front of you, or with `focus` false (an agent or a script asked), beside what you're doing.
    private func show(_ uri: String, split: SplitDirection?, focus: Bool) {
        if focus { area.open(uri, split: split) } else { area.showAside(uri, split: split) }
    }

    private func createSession(
        _ create: SessionCreate, split: SplitDirection?, focus: Bool = true, beside pane: String? = nil,
        created: ((Session) -> Void)? = nil
    ) {
        let create = sized(create, split: split)
        let app = app
        Task {
            guard let session = await app.call(create) else { return }
            app.upsert(session)
            created?(session)
            let uri = TabURI.session(session.id)
            if let pane { area.open(uri, split: split, beside: pane) } else { show(uri, split: split, focus: focus) }
        }
    }

    /// Returns `create` set to the size its terminal will have. `split` says it opens in a new pane beside or below.
    func sized<M: StartsSized>(_ create: M, split: SplitDirection? = nil) -> M {
        var create = create
        if let (cols, rows) = terminalSize(split: split) {
            create.cols = cols
            create.rows = rows
        }
        return create
    }

    /// Returns the size the new terminal will have, so the shell's first screen isn't drawn for another width (which
    /// leaves zsh's stray "%" line, or an agent's banner wrapped twice). A split gets half the room, and a guess on the
    /// small side only leaves spare room.
    private func terminalSize(split: SplitDirection?) -> (Int, Int)? {
        guard
            let grid = area.focusedContent?.terminalGrid ?? area.contents.values.lazy.compactMap(\.terminalGrid).first
                ?? app.workbench.terminalGrid
        else { return nil }
        switch split {
        case .right?: return (max(20, grid.cols / 2 - 1), grid.rows)
        case .down?: return (grid.cols, max(5, grid.rows / 2 - 1))
        case nil: return (grid.cols, grid.rows)
        }
    }
}

extension EditorArea {
    /// The starter for agents and terminals in this area.
    var starter: SessionStarter { SessionStarter(area: self) }
}
