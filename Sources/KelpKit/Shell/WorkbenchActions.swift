import AppKit
import Core
import WorkbenchKit

/// Entry points everything uses to act on the window: open URIs, switch workspaces, focus agents.
@MainActor
extension Workbench {
    /// Every unsaved file in the app: the main window's loaded workspaces'.
    package var editedFiles: [SavableTab] { window?.editors.editedFiles ?? [] }
    /// The editor area with the keyboard: the workspace on screen's.
    /// Nil while a page is on screen: what acts on tabs waits until a workspace is back.
    package var editor: EditorArea? { page == nil ? window?.editors.current : nil }
    /// The editor area for what adds a tab (a command in a terminal, an agent): a page on screen gives way to the
    /// workspace, as for `open`.
    package var editorForNewTab: EditorArea? { area(nil) }

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

    func showWorkspace(number number: Int) {
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

    /// The sessions the sidebar lists: a run hidden in the Run menu is there, not in the sidebar.
    var shownSessions: [Session] {
        let hidden = app.extensions.all.runs?.hidden() ?? [], inTab = Set(app.uiState.strings(Session.inTabKey))
        return app.sessions.filter { !hidden.contains($0.id) && !isOnLine($0, inTab: inTab) }
    }
    /// No tab of its own: a run put away in the Run menu, or a command its agent's line shows.
    package func isHidden(_ sid: String) -> Bool {
        app.extensions.all.runs?.hidden().contains(sid) == true || app.session(sid).map { isOnLine($0) } == true
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

/// `kelp://` links (from a browser, a script, another app). Looking things up is free; adding a project, or opening a file
/// outside them, asks first.
@MainActor
struct KelpLinks {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    func handle(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "workspace" where app.worktree(id) != nil: app.workbench.show(workspace: id)
        case "session" where app.session(id) != nil: app.workbench.focus(session: id)
        case "open":
            // Standardized (`..` resolved) before it's compared with the projects': `proj/../../x` is no project of theirs.
            guard
                let path = query.first(where: { $0.name == "path" })?.value.map({
                    (($0 as NSString).expandingTildeInPath as NSString).standardizingPath
                }),
                FileManager.default.fileExists(atPath: path)
            else {
                Banner.show(String(localized: "Kelp can't find the file in that link."), style: .error)
                return
            }
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            if !dir.boolValue {
                openFile(path, line: query.first { $0.name == "line" }?.value.flatMap(Int.init))
            } else if app.repos.contains(where: { IDE.inside(path, $0.path) }) {   // a link out of a project isn't in it
                app.workbench.addProject(path: path)   // already a project: just shows it
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "Add “\((path as NSString).lastPathComponent)” to Kelp?")
                alert.informativeText = String(localized: "A link asked to open \(path) as a project.")
                alert.addButton(withTitle: String(localized: "Add Project"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                Task { if await runSheet(alert) == .alertFirstButtonReturn { app.workbench.addProject(path: path) } }
            }
        default: Banner.show(String(localized: "Kelp doesn't know the link \(url.absoluteString)."), style: .error)
        }
        NSApp.activate()
    }

    private func openFile(_ path: String, line: Int?) {
        let worktree = app.worktree(holding: path)
        whenAllowed(path) {
            app.workbench.open(TabURI.file(path) + (line.map { "#L\($0)" } ?? ""), workspace: worktree?.id)
        }
    }

    /// A project's file opens right away; one elsewhere once the user says so (`ask`, a sheet), as a folder does: any web
    /// page can send a `kelp://` link, and a preview's page may be a cloned repository's (`PreviewLinks`).
    func whenAllowed(
        _ path: String,
        ask: @escaping @MainActor (String) async -> Bool = askToOpen,
        _ open: @escaping @MainActor () -> Void
    ) {
        guard !isKnown(path) else { return open() }
        Task { if await ask(path) { open() } }
    }

    static func askToOpen(_ path: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open “\((path as NSString).lastPathComponent)”?")
        alert.informativeText = String(localized: "A link asked to open \(path), which is outside your projects.")
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    /// In a project's folder, one of its workspaces' or Kelp's own home, once `..` and links are followed.
    func isKnown(_ path: String) -> Bool {
        (app.repos.map(\.path) + app.worktrees.map(\.path) + [Paths.root.path]).contains { IDE.inside(path, $0) }
    }
}

/// IDE actions agents ask for through the daemon (`kelp open`, `kelp ui`). They never pull Kelp to the front, switch the
/// workspace on screen or take the keys unless asked (`--focus`): a tab for another workspace waits there.
@MainActor
struct UIRequests {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    func handle(_ event: UIEvent) {
        switch event.action {
        case "open":
            guard let uri = event.uri else { return }
            let split = event.split.flatMap(SplitDirection.init(rawValue:))
            let focus = event.focus == true
            if let wid = event.worktreeId, wid != app.workbench.workspaceId, !focus, app.workbench.workspaceId != nil {
                app.workbench.window?.editors.openInBackground(uri, workspace: wid)
                return
            }
            // `kelp open`: the user's or their agent's own
            if TabURI.runs(uri) {
                app.workbench.runURI(uri, split: split, workspace: event.worktreeId, focus: focus)
            } else if focus {
                app.workbench.open(uri, split: split, workspace: event.worktreeId)
            } else {
                app.workbench.showAside(uri, split: split, workspace: event.worktreeId)
            }
            if focus { NSApp.activate() }
        case "command":
            guard let id = event.id else { return }
            if id == "extensions.reload" {
                app.extensions.reload()
                return
            }
            if id == "window.shot", let shotWindow = app.workbench.window?.window,
                let path = event.args?["path"]?.string
            {
                // A picture, by its name: `kelp shot` (an agent's too) writes a .png, never over a source file it was told.
                guard path.lowercased().hasSuffix(".png") else {
                    return Banner.show(String(localized: "A window's picture is a .png file."), style: .error)
                }
                AppDelegate.snap(shotWindow, to: path)
                return
            }
            guard let command = app.extensions.command(id) else {
                Banner.show(String(localized: "Unknown command \(id)"), style: .error)
                return
            }
            if case .object(let args)? = event.args { command.run(args) } else { command.run([:]) }
        default: break
        }
    }
}

/// A file (or lines in it) handed to an agent or copied as a link.
@MainActor
package struct FileActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// "Sources/App.swift:12-30": workspace-relative, the way agents read a reference.
    func reference(_ path: String, lines: ClosedRange<Int>?) -> String {
        let root = app.worktree(app.workbench.workspaceId)?.path ?? ""
        let rel = !root.isEmpty && path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let suffix = lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return IDE.escapedPath(rel) + suffix
    }

    /// The agent the user was last with in this workspace (never a plain terminal).
    package var targetAgent: Session? {
        let model = app, wid = app.workbench.workspaceId
        if let session = app.workbench.focusedSession.flatMap(model.session), session.agent != "shell",
            session.worktreeId == wid,
            session.status != .exited
        {
            return session
        }
        return model.sessions.last { $0.worktreeId == wid && $0.isChat && $0.status != .exited }
    }

    /// Types the reference into the agent's prompt without pressing Return, and shows the agent.
    package func sendToAgent(_ path: String, lines: ClosedRange<Int>? = nil) {
        guard let agent = targetAgent else {
            Banner.show(
                String(localized: "No agent on this screen. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task { await app.call(SessionSend(id: agent.id, text: reference(path, lines: lines) + " ", enter: false)) }
        app.workbench.focus(session: agent.id)
    }

    /// Words into the agent's prompt, not sent: the user adds what to do with them.
    package func sendToAgent(text: String) {
        guard let agent = targetAgent else {
            Banner.show(
                String(localized: "No agent on this screen. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task { await app.call(SessionSend(id: agent.id, text: text + " ", enter: false)) }
        app.workbench.focus(session: agent.id)
    }

    package func copyWebLink(_ path: String, lines: ClosedRange<Int>? = nil) {
        Task {
            guard let url = await app.call(GitWebURL(path: path, start: lines?.lowerBound, end: lines?.upperBound))
            else { return }
            copyText(url)
            Banner.show(String(localized: "Link copied"))
        }
    }

    package func copyReference(_ path: String, lines: ClosedRange<Int>?) {
        copyText(reference(path, lines: lines))
    }
}

/// A git step that failed for a reason an agent can fix (hooks, a rejected push, conflicts): the error banner
/// offers to hand it to the workspace's agent, with the error, as a prompt waiting for Return.
@MainActor
package struct GitFix {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    package func offer(_ error: String, recipe: String, worktree wid: String, vars: [String: String] = [:]) {
        guard FileActions(app).targetAgent != nil else {
            Banner.show(error, style: .error)
            return
        }
        Banner.show(
            error, style: .error,
            action: (
                String(localized: "Ask Agent to Fix"),
                {
                    send(recipe, worktree: wid, vars: vars.merging(["error": error]) { a, _ in a })
                }
            ))
    }

    package func send(_ recipe: String, worktree wid: String, vars: [String: String]) {
        guard let agent = FileActions(app).targetAgent else { return }
        Task {
            if await type(recipe, worktree: wid, vars: vars, into: agent.id) { app.workbench.focus(session: agent.id) }
        }
    }

    /// The recipe typed into the session, not sent: other people's text (errors, CI logs, review comments) waits for Return.
    package func type(_ recipe: String, worktree wid: String, vars: [String: String], into sid: String) async -> Bool {
        guard let text = await app.call(RecipeRender(id: wid, name: recipe, vars: vars)) else { return false }
        await app.call(SessionSend(id: sid, text: text, enter: false))
        return true
    }
}
