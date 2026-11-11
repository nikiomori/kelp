import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Entry points everything uses to act on the window: open URIs, switch workspaces, focus agents.
@MainActor
extension Workbench {
    /// Every unsaved file in the app: the main window's loaded workspaces'.
    package var editedFiles: [SavableTab] { window?.editors.editedFiles ?? [] }
    /// The editor area with the keyboard: the workspace on screen's.
    /// Nil while a page is on screen: what acts on tabs waits until a workspace is back.
    var editor: EditorArea? { page == nil ? window?.editors.current : nil }
    /// What starts agents and terminals in the workspace on screen; nil with none (or a page) on screen.
    package var starter: SessionStarter? { editor?.starter }
    /// What starts them for what adds a tab (a command in a terminal, an agent): a page on screen gives way to the
    /// workspace, as for `open`.
    package var starterForNewTab: SessionStarter? { area(nil)?.starter }

    // What a built-in may do to the workspace on screen's tabs (it never gets the editor area itself).
    /// The tab with focus there, built.
    package var focusedContent: TabContent? { editor?.focusedContent }
    /// Every tab open there, by URI.
    package var tabURIs: [String] { editor?.layout.allTabs.map(\.uri) ?? [] }
    /// `new` in the tab that shows `old` there (an untitled file saved under a name).
    package func replace(_ old: String, with new: String) { editor?.replace(old, with: new) }
    /// The keys back to the tab in front there.
    package func focusTab() { editor?.focusSelected() }
    /// The focused tab into a new pane to the right or below; a beep with no workspace on screen.
    package func split(_ direction: SplitDirection) {
        guard let editor else { return NSSound.beep() }
        editor.splitFocused(direction)
    }
    /// Agents side by side, or every tab in one pane (⌃⌘T); a beep with no workspace on screen.
    package func toggleSideBySide() {
        guard let editor else { return NSSound.beep() }
        editor.toggleSideBySide()
    }

    package func show(workspace id: String) { show(workspace: id, remember: true) }

    private func show(workspace id: String, remember: Bool) {
        guard workspaceId != id || page != nil || window?.editors.current == nil else { return }
        page = nil
        workspaceId = id
        noteShown()
        if remember { history.visit(id) }
        window?.showWorkspace(id)
    }

    /// A page in place of the workspace (`page`).
    func show(page uri: String) {
        guard page != uri, window?.showPage(uri) == true else { return }
        page = uri
        noteShown()
    }

    /// ⌃⌘← / ⌃⌘→: the workspace shown before / after this one (closed ones are skipped).
    /// The places Back (-1) or Forward (1) can reach, nearest first: where each is in the history, and its name.
    func places(_ step: Int) -> [(Int, String)] {
        var seen = Set([workspaceId ?? ""]), out: [(Int, String)] = []
        var index = history.at + step
        while history.visits.indices.contains(index) {
            let id = history.visits[index]
            if seen.insert(id).inserted, let worktree = app.worktree(id) {
                out.append((index, app.groupName(worktree) ?? app.projectName(worktree.repoId) ?? worktree.displayName))
            }
            index += step
        }
        return out
    }
    func go(to index: Int) { show(workspace: history.go(to: index), remember: false) }

    func goBack(_ step: Int) {
        guard let index = visit(step) else {
            NSSound.beep()
            return
        }
        show(workspace: history.go(to: index), remember: false)
    }

    /// Where Back (-1) / Forward (1) would go: nil when there's nothing that way (the title bar's arrows grey out).
    func visit(_ step: Int) -> Int? {
        history.target(step, current: workspaceId) { app.worktree($0) != nil }
    }

    package func open(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil, focus: Bool = true) {
        area(workspace)?.open(uri, split: split, focus: focus)
    }

    /// A tab for a workspace that isn't on screen, without showing it (a run started there).
    package func openInBackground(_ uri: String, workspace id: String) {
        window?.editors.openInBackground(uri, workspace: id)
    }

    /// `EditorArea.runURI`, for what Kelp itself asks to run.
    func runURI(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil, focus: Bool = true) {
        area(workspace)?.runURI(uri, split: split, focus: focus)
    }
    /// `EditorArea.showAside`, for what an agent or a script asks to show.
    func showAside(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil) {
        area(workspace)?.showAside(uri, split: split)
    }

    private func area(_ workspace: String?) -> EditorArea? {
        if let id = workspace ?? workspaceId, id != workspaceId || page != nil { show(workspace: id) }
        if workspaceId == nil, let first = app.worktrees.first { show(workspace: first.id) }
        return window?.editors.current
    }

    /// Restart: the new session takes the old one's tab in the workspace it belongs to, which may not be the one on screen
    /// (Restart from the sidebar).
    func replace(session old: String, with new: String, workspace: String?) {
        let oldURI = TabURI.session(old), newURI = TabURI.session(new)
        if let workspace, workspace != workspaceId {
            window?.editors.replaceInBackground(oldURI, with: newURI, workspace: workspace)
            return
        }
        window?.editors.current?.replace(oldURI, with: newURI)
    }

    package func focus(session id: String) {
        guard let session = app.session(id) else { return }
        if let wid = session.worktreeId, wid != workspaceId || page != nil { show(workspace: wid) }
        window?.editors.current?.focus(session: id)
        // Opening a finished agent is reading it; a question stays marked until it's answered (typing clears it).
        if session.unread, session.status == .done { Task { await app.call(SessionMarkRead(id: id)) } }
    }

    /// No notification for an agent whose tab the user is looking at.
    func isViewing(session id: String) -> Bool {
        window?.window?.isKeyWindow == true && editor?.layout.focusedGroup?.selectedTab?.uri == TabURI.session(id)
    }

    /// Workspaces in sidebar order (⌃1–9, ⌃⌘↑ / ↓).
    var workspacesInOrder: [Worktree] { app.projects.flatMap { app.workspaces(of: $0) } }

    func showWorkspace(offset: Int) {
        let all = workspacesInOrder
        guard !all.isEmpty else {
            NSSound.beep()
            return
        }
        let index = all.firstIndex { $0.id == workspaceId }.map { ($0 + offset + all.count) % all.count } ?? 0
        show(workspace: all[index].id)
    }

    func showWorkspace(number: Int) {
        let all = workspacesInOrder
        guard all.indices.contains(number - 1) else {
            NSSound.beep()
            return
        }
        show(workspace: all[number - 1].id)
    }

    /// The chat's row, wherever it is: the screen you're on stays.
    func closeChat(session id: String) {
        if let wid = app.session(id)?.worktreeId { window?.editors.closeChat(id, workspace: wid) }
    }

    /// Open Quickly (⌘P), the field starting with `text` (":" for Go to Line).
    package func openQuickly(text: String = "") { app.quickOpen.show(commandsOnly: false, text: text) }
    /// The tmux sessions to attach to, listed where the palette shows.
    package func showTmuxSessions() { app.quickOpen.showTmux() }
    /// A built-in's own list there (Open Database): `rows` makes its rows from what's typed.
    package func showList(
        _ placeholder: String, keys: String, rows: @escaping @MainActor (String) async -> [QuickItem]
    ) { app.quickOpen.showList(placeholder, keys: keys, rows: rows) }

    /// ⇧⌘U: the next agent that asked something or finished, wherever it is.
    package func showNextNeedingAttention() {
        let current = editor?.layout.focusedGroup?.selectedTab.map(\.uri).flatMap {
            TabURI.scheme($0) == "session" ? TabURI.body($0) : nil
        }
        guard let session = AttentionQueue(app).next(after: current) else {
            NSSound.beep()
            return
        }
        focus(session: session.id)
    }

    package func closeTab(uri: String, remember: Bool = true) {
        guard let area = window?.editors.current, area.layout.tab(uri: uri) != nil,
            let tab = area.layout.tab(uri: uri)
        else { return }
        area.closeTab(tab.id, remember: remember)
    }

    /// Takes a tab off the screen without closing what it shows: a run hidden in the Run menu keeps running.
    package func hideTab(uri: String) {
        guard let area = window?.editors.current, area.layout.tab(uri: uri) != nil,
            let tab = area.layout.tab(uri: uri)
        else { return }
        area.drop(tab.id)
    }

    /// The sessions the sidebar lists: one a built-in keeps out of sight (a run hidden in the Run menu) isn't there.
    var shownSessions: [Session] {
        let hidden = keptHidden, inTab = Set(app.uiState.strings(Session.inTabKey))
        return app.sessions.filter { !hidden.contains($0.id) && !isOnLine($0, inTab: inTab) }
    }
    /// No tab of its own: kept out of sight by a built-in (a run put away in the Run menu), or a command its agent's line
    /// shows.
    package func isHidden(_ sid: String) -> Bool {
        keptHidden.contains(sid) || app.session(sid).map { isOnLine($0) } == true
    }
    private var keptHidden: Set<String> {
        app.extensions.all.sessionHidden.reduce(into: []) { $0.formUnion($1()) }
    }
    /// A command its agent's line shows, not moved to a tab of its own (`openInTab`).
    func isOnLine(_ session: Session, inTab: Set<String>? = nil) -> Bool {
        app.sessions.owner(of: session) != nil
            && !(inTab ?? Set(app.uiState.strings(Session.inTabKey))).contains(session.id)
    }
    /// A command off its agent's line, as any tab (it stays one; only live ones are kept in the list).
    package func openInTab(_ sid: String) {
        let live = app.uiState.strings(Session.inTabKey).filter {
            app.session($0).map { $0.status != .exited } ?? false
        }
        app.uiState[Session.inTabKey] = .array((live.filter { $0 != sid } + [sid]).map(JSONValue.string))
        open(TabURI.session(sid), workspace: app.session(sid)?.worktreeId)
    }

    func addProject() {
        // A new folder made here is a new project (asked whether to `git init` it). Clone and SSH are their own commands.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a project folder, or make a new one")
        panel.prompt = String(localized: "Add Project")
        let chosen = { [self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            addProject(path: url.path)
        }
        // A sheet on the window, not an app-modal panel that stops everything else.
        if let host = NSApp.mainWindow ?? NSApp.keyWindow {
            panel.beginSheetModal(for: host, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    /// A folder dropped on the Dock icon or the sidebar, `open -a Kelp .`, or picked in Add Project: its project on screen
    /// (added first if it's new; a folder inside a repository adds the repository).
    func addProject(path: String) {
        Task {
            let model = app
            await model.waitForConnection()   // opened at launch
            guard let rid = await repoAdd(path, model)?.id else { return }
            let ws = model.repo(rid).map(model.workspaces(of:)) ?? []
            if let screen = ws.first(where: { $0.id == workspaceId }) ?? ws.first { show(workspace: screen.id) }
        }
    }

    /// The folder's project; one outside any repository is asked about first: made one (`git init`) or added as it is.
    private func repoAdd(_ path: String, _ model: AppModel) async -> Repo? {
        do { return try await model.get(RepoAdd(path: path)) } catch let error as RPCError
            where error.code == RepoAdd.notARepository.code
        {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\((path as NSString).lastPathComponent)” isn't a Git repository")
            alert.informativeText = String(
                localized: "Initialize Git to see changes, diffs and branches here, or open the folder without it.")
            alert.addButton(withTitle: String(localized: "Initialize Git"))
            alert.addButton(withTitle: String(localized: "Open Without Git"))
            alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
            switch await runSheet(alert) {
            case .alertFirstButtonReturn: return await model.call(RepoAdd(path: path, init: true))
            case .alertSecondButtonReturn: return await model.call(RepoAdd(path: path, init: false))
            default: return nil
            }
        } catch {
            Banner.show(AppModel.message(error), style: .error)
            return nil
        }
    }

    /// Files and folders from Finder (dropped on the window or the Dock icon, `open -a Kelp <path>`): a folder becomes a
    /// project, a file opens as a tab (`open`: in that editor area, else wherever ⌘O would).
    package func open(files urls: [URL], with open: (@MainActor (String) -> Void)? = nil) {
        for url in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) else { continue }
            if dir.boolValue {
                addProject(path: url.path)
            } else if let open {
                open(TabURI.file(url.path))
            } else {
                self.open(TabURI.file(url.path))
            }
        }
    }

    /// The files a drag carries (from Finder or the Files panel).
    static func files(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL]
            ?? []
    }

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

    /// ⇧⌘N: a screen of its own under a heading, named by its first prompt, with an agent on it.
    func newGroup(repo: String? = nil) {
        Task {
            guard let rid = await project(repo) else { return }
            if let id = await app.call(WorkspaceCreate(repoId: rid))?.id { await startChat(on: id) }
        }
    }

    /// ⌃⌘N: the same with code of its own, a new branch from the project's base in its own folder. The first prompt names
    /// both. A .kelp.yaml not yet trusted asks once the chat is there, so its setup waits for nobody.
    func newBranch(repo: String? = nil) {
        Task {
            guard let rid = await project(repo), let made = await app.call(WorktreeCreate(repoId: rid)) else { return }
            let id = made.worktree.id
            await startChat(on: id)
            if made.setupNeedsTrust == true { await app.extensions.all.runs?.setup(id, nil) }
        }
    }

    /// ⌥⌃⌘N, "New Chat on Branch…": the sheet (`NewChatSheet`) for a branch with a name, one that's there, or a pull
    /// request, and the agent to start on it.
    func newBranchAsking(repo: String? = nil) {
        Task {
            guard let rid = await project(repo) else { return }
            let worktree = app.worktrees.first { $0.repoId == rid }, base = app.repo(rid)?.baseBranch ?? "main"
            var branches: BranchInfo?
            if let worktree { branches = await app.quiet(GitBranches(id: worktree.id)) }
            let prs = await app.quiet(GitHubPRs(repoId: rid, filter: "open")) ?? []
            let agents = app.catalog.installed(app.catalog.all).filter { $0.id != "shell" }.map {
                (id: $0.id, name: $0.name)
            }
            let sheet = NewChatSheet(
                local: branches?.local ?? [base], remote: branches?.remote ?? [], base: base, prs: prs, agents: agents,
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
            if made.setupNeedsTrust == true { await app.extensions.all.runs?.setup(made.worktree.id, choice.pr) }
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
            var request = SessionCreate(cwd: cwd, worktreeId: id, agent: kind)
            if let grid = terminalGrid {
                request.cols = grid.cols
                request.rows = grid.rows
            }
            chat = await app.call(request)
        }
        if let chat {
            app.upsert(chat)
            focus(session: chat.id)
        } else {
            show(workspace: id)
        }
    }
}
