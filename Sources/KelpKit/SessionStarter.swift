import AppKit
import Core
import WorkbenchKit

/// Starting agents and terminals in a workspace's editor area, each in a tab there: the session asked of the daemon at
/// the size its terminal will have, then its tab in front of you, or beside what you're doing. Built-ins get one for the
/// workspace on screen (`Workbench.starter`), never the editor area itself.
@MainActor
package struct SessionStarter {
    let area: EditorArea
    private var app: AppModel { area.app }
    private var workspaceId: String { area.workspaceId }

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
        let app = app, area = area
        Task {
            guard let shell = await app.call(create) else { return }
            app.upsert(shell)
            area.replace(uri, with: TabURI.session(shell.id))
        }
    }

    /// In front of you, or (`focus` false, an agent or a script asked) beside what you're doing.
    private func show(_ uri: String, split: SplitDirection?, focus: Bool) {
        if focus { area.open(uri, split: split) } else { area.showAside(uri, split: split) }
    }

    private func createSession(
        _ create: SessionCreate, split: SplitDirection?, focus: Bool = true, created: ((Session) -> Void)? = nil
    ) {
        var create = create
        if let (cols, rows) = terminalSize(split: split) {
            create.cols = cols
            create.rows = rows
        }
        let app = app
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
    /// What starts agents and terminals in this area.
    var starter: SessionStarter { SessionStarter(area: self) }
}
