import AppKit
import Core
import DesignKit
import WorkbenchKit

/// A new chat, group or branch: where it goes (the project asked, else the one shown) and its agent's start.
@MainActor
extension Workbench {
    /// New isolated workspace in the project on screen (or the first one).
    /// ⌘N, and New Chat on a project's row: a new agent on the screen you're on, or on that project's own from another project.
    /// With nothing on screen it's a chat with no project. `cwd`: in that folder (New Chat in Folder…).
    func newChat(repo: String? = nil, cwd: String? = nil) {
        Task {
            // Right after launch the project list may not be in yet: ⌘N must not turn into "Add Project".
            let model = app
            await model.waitForConnection()
            let here = model.worktree(workspaceId)
            guard
                let rid = repo ?? here?.repoId ?? model.repos.first(where: NoProject.holds)?.id ?? model.repos.first?.id
            else {
                addProject()
                return
            }
            guard let screen = model.repo(rid).flatMap({ newChatScreen(in: $0, current: here, rows: model.worktrees) })
            else {
                return
            }
            await startChat(on: screen.id, cwd: cwd)
        }
    }

    /// ⇧⌘N: a screen of its own under a heading, with nothing on it yet: its empty screen offers an agent, a terminal,
    /// a file, as "+" does. It lives while it's on screen (`WorkspaceActions.left`); its first prompt names it.
    func newGroup(repo: String? = nil) {
        Task {
            guard let rid = await project(repo) else { return }
            if let id = await app.call(WorkspaceCreate(repoId: rid))?.id { show(workspace: id) }
        }
    }

    /// ⌃⌘N, and Own Branch on a group's empty screen: the same with code of its own, a new branch from the
    /// project's base in its own folder. The first prompt names both. A .kelp.yaml not yet trusted asks once the screen
    /// is there, so its setup waits for nobody.
    func newBranch(repo: String? = nil) {
        Task {
            guard let rid = await project(repo), let made = await app.call(WorktreeCreate(repoId: rid)) else { return }
            let id = made.worktree.id
            show(workspace: id)
            if made.setupNeedsTrust == true { await KelpFile(app: app).setup(id, pullRequest: nil) }
        }
    }

    /// ⌥⌃⌘N, "New Group on Branch…": the sheet (`NewChatSheet`) for a branch with a name, one that's there, or a pull
    /// request, and the agent to start on it.
    func newBranchAsking(repo: String? = nil) {
        Task {
            guard let rid = await project(repo) else { return }
            let worktree = app.worktrees.first { $0.repoId == rid }, base = app.repo(rid)?.baseBranch ?? "main"
            var branches: BranchInfo?
            if let worktree { branches = await app.quiet(GitBranches(id: worktree.id)) }
            // The project's watch's, else read once; none (gh missing, or not read): a branch or a name still.
            let prs: [GitHub.PullRequest]
            do { prs = try await PRsEvent.open(rid, in: app) } catch { prs = [] }
            let agents = app.catalog.installed(app.catalog.all).filter { $0.id != Session.shellAgent }.map {
                (id: $0.id, name: $0.name)
            }
            let sheet = NewChatSheet(
                local: branches?.local ?? [base], remote: branches?.remote ?? [], base: base, prs: prs,
                agents: agents,
                picked: app.catalog.defaultAgent)
            let alert = NSAlert()
            alert.messageText = String(localized: "New Chat on Branch")
            alert.accessoryView = sheet.view
            alert.addButton(withTitle: String(localized: "Start"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = sheet.name
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            let choice = sheet.choice
            guard let made = await app.call(NewChatSheet.request(choice, repo: rid)) else { return }
            await startChat(on: made.worktree.id, agent: choice.agent)
            if made.setupNeedsTrust == true { await KelpFile(app: app).setup(made.worktree.id, pullRequest: choice.pr) }
        }
    }

    /// The project a new screen goes to: the one asked for, the one on screen, or the first; with none, adding one.
    private func project(_ repo: String?) async -> String? {
        let model = app
        await model.waitForConnection()
        guard let id = repo ?? model.worktree(workspaceId)?.repoId ?? model.repos.first?.id else {
            addProject()
            return nil
        }
        return id
    }

    /// A new agent of the default kind, started before anything shows: it comes as a row of its own. With no agent on this
    /// Mac the empty screen offers to install one.
    private func startChat(on id: String, cwd: String? = nil, agent: String? = nil) async {
        var chat: Session?
        if let kind = agent ?? app.catalog.startable {
            chat = await app.call(sized(SessionCreate(cwd: cwd, worktreeId: id, agent: kind)))
        }
        if let chat {
            app.upsert(chat)
            focus(session: chat.id)
        } else {
            show(workspace: id)
        }
    }
}
