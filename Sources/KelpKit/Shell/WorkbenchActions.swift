import AppKit
import Core
import WorkbenchKit

/// Entry points everything uses to act on the window: open URIs, switch workspaces, focus agents.
@MainActor
extension Workbench {
    /// Every unsaved file in the app: the main window's loaded workspaces'.
    package var editedFiles: [SavableTab] { window?.editors.editedFiles ?? [] }
    /// The editor area with the keyboard: the workspace on screen's.
    package var editor: EditorArea? { window?.editors.current }

    package func show(workspace id: String) { show(workspace: id, remember: true) }

    private func show(workspace id: String, remember: Bool) {
        guard workspaceId != id || window?.editors.current == nil else { return }
        workspaceId = id
        if remember { history.visit(id) }
        window?.showWorkspace(id)
    }

    /// ⌃⌘← / ⌃⌘→: the workspace shown before / after this one (closed ones are skipped).
    /// The places Back (-1) or Forward (1) can reach, nearest first: where each is in the history, and its name.
    func places(_ step: Int) -> [(Int, String)] {
        var seen = Set([workspaceId ?? ""]), out: [(Int, String)] = []
        var i = history.at + step
        while history.visits.indices.contains(i) {
            let id = history.visits[i]
            if seen.insert(id).inserted, let w = app.worktree(id) { out.append((i, app.groupName(w) ?? app.projectName(w.repoId) ?? w.displayName)) }
            i += step
        }
        return out
    }
    func go(to i: Int) { show(workspace: history.go(to: i), remember: false) }

    func goBack(_ step: Int) {
        guard let i = visit(step) else { NSSound.beep(); return }
        show(workspace: history.go(to: i), remember: false)
    }

    /// Where Back (-1) / Forward (1) would go: nil when there's nothing that way (the title bar's arrows grey out).
    func visit(_ step: Int) -> Int? {
        history.target(step, current: workspaceId) { app.worktree($0) != nil }
    }

    package func open(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil, focus: Bool = true) {
        area(workspace)?.open(uri, split: split, focus: focus)
    }

    /// `EditorArea.runURI`, for what Kelp itself asks to run.
    func runURI(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil, focus: Bool = true) {
        area(workspace)?.runURI(uri, split: split, focus: focus)
    }
    /// `EditorArea.showAside`, for what an agent or a script asks to show.
    func showAside(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil) { area(workspace)?.showAside(uri, split: split) }

    private func area(_ workspace: String?) -> EditorArea? {
        if let workspace, workspace != workspaceId { show(workspace: workspace) }
        if workspaceId == nil, let first = app.worktrees.first { show(workspace: first.id) }
        return window?.editors.current
    }

    /// Restart: the new session takes the old one's tab in the workspace it belongs to, which may not be the one on screen
    /// (Restart from the sidebar).
    func replace(session old: String, with new: String, workspace: String?) {
        let o = TabURI.session(old), n = TabURI.session(new)
        if let workspace, workspace != workspaceId { window?.editors.replaceInBackground(o, with: n, workspace: workspace); return }
        window?.editors.current?.replace(o, with: n)
    }

    package func focus(session id: String) {
        guard let s = app.session(id) else { return }
        if let w = s.worktreeId, w != workspaceId { show(workspace: w) }
        window?.editors.current?.focus(session: id)
        // Opening a finished agent is reading it; a question stays marked until it's answered (typing clears it).
        if s.unread, s.status == .done { Task { await app.call(SessionMarkRead(id: id)) } }
    }

    /// No notification for an agent whose tab the user is looking at.
    func isViewing(session id: String) -> Bool {
        window?.window?.isKeyWindow == true && editor?.layout.focusedGroup?.selectedTab?.uri == TabURI.session(id)
    }

    /// Workspaces in sidebar order (⌃1–9, ⌃⌘↑ / ↓).
    var workspacesInOrder: [Worktree] { app.projects.flatMap { app.workspaces(of: $0) } }

    func showWorkspace(offset: Int) {
        let all = workspacesInOrder
        guard !all.isEmpty else { NSSound.beep(); return }
        let i = all.firstIndex { $0.id == workspaceId }.map { ($0 + offset + all.count) % all.count } ?? 0
        show(workspace: all[i].id)
    }

    func showWorkspace(number n: Int) {
        let all = workspacesInOrder
        guard all.indices.contains(n - 1) else { NSSound.beep(); return }
        show(workspace: all[n - 1].id)
    }

    /// The chat's row, wherever it is: the screen you're on stays.
    func closeChat(session id: String) {
        if let w = app.session(id)?.worktreeId { window?.editors.closeChat(id, workspace: w) }
    }

    /// ⇧⌘U: the next agent that asked something or finished, wherever it is.
    package func showNextNeedingAttention() {
        let current = editor?.layout.focusedGroup?.selectedTab.map(\.uri).flatMap { TabURI.scheme($0) == "session" ? TabURI.body($0) : nil }
        guard let s = AttentionQueue(app).next(after: current) else { NSSound.beep(); return }
        focus(session: s.id)
    }

    package func closeTab(uri: String, remember: Bool = true) {
        guard let e = window?.editors.current, e.layout.tab(uri: uri) != nil,
              let t = e.layout.tab(uri: uri) else { return }
        e.closeTab(t.id, remember: remember)
    }

    /// Takes a tab off the screen without closing what it shows: a run hidden in the Run menu keeps running.
    func hideTab(uri: String) {
        guard let e = window?.editors.current, e.layout.tab(uri: uri) != nil,
              let t = e.layout.tab(uri: uri) else { return }
        e.drop(t.id)
    }

    func addProject() {
        // A new folder made here is a new project (asked whether to `git init` it). Clone and SSH are their own commands.
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = String(localized: "Choose a project folder, or make a new one"); p.prompt = String(localized: "Add Project")
        let chosen = { [self] (r: NSApplication.ModalResponse) in
            guard r == .OK, let u = p.url else { return }
            addProject(path: u.path)
        }
        // A sheet on the window, not an app-modal panel that stops everything else.
        if let w = NSApp.mainWindow ?? NSApp.keyWindow { p.beginSheetModal(for: w, completionHandler: chosen) } else { p.begin(completionHandler: chosen) }
    }

    /// A folder dropped on the Dock icon or the sidebar, `open -a Kelp .`, or picked in Add Project: its project on screen
    /// (added first if it's new; a folder inside a repository adds the repository).
    func addProject(path: String) {
        Task {
            let m = app
            await m.waitForConnection()   // opened at launch
            guard let rid = await repoAdd(path, m)?.id else { return }
            await m.refresh()
            let ws = m.repo(rid).map(m.workspaces(of:)) ?? []
            if let w = ws.first(where: { $0.id == workspaceId }) ?? ws.first { show(workspace: w.id) }
        }
    }

    /// The folder's project; one outside any repository is asked about first: made one (`git init`) or added as it is.
    private func repoAdd(_ path: String, _ m: AppModel) async -> Repo? {
        do { return try await m.get(RepoAdd(path: path)) } catch let e as RPCError where e.code == RepoAdd.notARepository.code {
            let a = NSAlert()
            a.messageText = String(localized: "“\((path as NSString).lastPathComponent)” isn't a Git repository")
            a.informativeText = String(localized: "Initialize Git to see changes, diffs and branches here, or open the folder without it.")
            a.addButton(withTitle: String(localized: "Initialize Git"))
            a.addButton(withTitle: String(localized: "Open Without Git"))
            a.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
            switch await runSheet(a) {
            case .alertFirstButtonReturn: return await m.call(RepoAdd(path: path, init: true))
            case .alertSecondButtonReturn: return await m.call(RepoAdd(path: path, init: false))
            default: return nil
            }
        } catch {
            Banner.show(AppModel.message(error), style: .error); return nil
        }
    }

    /// Files and folders from Finder (dropped on the window or the Dock icon, `open -a Kelp <path>`): a folder becomes a
    /// project, a file opens as a tab (`open`: in that editor area, else wherever ⌘O would).
    package func open(files urls: [URL], with open: (@MainActor (String) -> Void)? = nil) {
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue { addProject(path: u.path) } else if let open { open(TabURI.file(u.path)) } else { self.open(TabURI.file(u.path)) }
        }
    }

    /// The files a drag carries (from Finder or the Files panel).
    static func files(_ s: NSDraggingInfo) -> [URL] {
        s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// New isolated workspace in the project on screen (or the first one).
    /// ⌘N, and New Chat on a project's row: a new agent on the screen you're on, or on that project's own from another project.
    /// With nothing on screen it's a chat with no project. `cwd`: in that folder (New Chat in Folder…).
    func newChat(repo: String? = nil, cwd: String? = nil) {
        Task {
            // Right after launch the project list may not be in yet: ⌘N must not turn into "Add Project".
            let m = app
            await m.waitForConnection()
            let here = m.worktree(workspaceId)
            guard let rid = repo ?? here?.repoId ?? m.repos.first(where: NoProject.holds)?.id ?? m.repos.first?.id else { addProject(); return }
            guard let w = m.repo(rid).flatMap({ newChatScreen(in: $0, current: here, rows: m.worktrees) }) else { return }
            await startChat(on: w.id, cwd: cwd)
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
            if made.setupNeedsTrust == true, let info = await app.scripts.load(id), info.setup != nil {
                await app.scripts.runKelp(id, "setup", info)
            }
        }
    }

    /// ⌥⌃⌘N, "New Chat on Branch…": the sheet (`NewChatSheet`) for a branch with a name, one that's there, or a pull
    /// request, and the agent to start on it.
    func newBranchAsking(repo: String? = nil) {
        Task {
            guard let rid = await project(repo) else { return }
            let w = app.worktrees.first { $0.repoId == rid }, base = app.repo(rid)?.baseBranch ?? "main"
            var b: BranchInfo?
            if let w { b = await app.quiet(GitBranches(id: w.id)) }
            let prs = await app.quiet(GitHubPRs(repoId: rid, filter: "open")) ?? []
            let agents = app.catalog.installed(app.catalog.all).filter { $0.id != "shell" }.map { (id: $0.id, name: $0.name) }
            let sheet = NewChatSheet(local: b?.local ?? [base], remote: b?.remote ?? [], base: base, prs: prs, agents: agents,
                                     picked: app.catalog.defaultAgent)
            let a = NSAlert()
            a.messageText = String(localized: "New Chat on Branch")
            a.accessoryView = sheet.view
            a.addButton(withTitle: String(localized: "Start"))
            a.addButton(withTitle: String(localized: "Cancel"))
            a.window.initialFirstResponder = sheet.name
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            let c = sheet.choice
            guard let made = await app.call(NewChatSheet.request(c, repo: rid)) else { return }
            await startChat(on: made.worktree.id, agent: c.agent)
            if made.setupNeedsTrust == true, let info = await app.scripts.load(made.worktree.id), info.setup != nil {
                await app.scripts.runKelp(made.worktree.id, "setup", info, pullRequest: c.pr)
            }
        }
    }

    /// The project a new screen goes to: the one asked for, the one on screen, or the first; with none, adding one.
    private func project(_ repo: String?) async -> String? {
        let m = app
        await m.waitForConnection()
        guard let id = repo ?? m.worktree(workspaceId)?.repoId ?? m.repos.first?.id else { addProject(); return nil }
        return id
    }

    /// A new agent of the default kind, started before anything shows: it comes as a row of its own. With no agent on this
    /// Mac the empty screen offers to install one.
    private func startChat(on id: String, cwd: String? = nil, agent: String? = nil) async {
        var chat: Session?
        if let a = agent ?? app.catalog.startable {
            var p = SessionCreate(cwd: cwd, worktreeId: id, agent: a)
            if let g = terminalGrid { p.cols = g.cols; p.rows = g.rows }
            chat = await app.call(p)
        }
        await app.refresh()
        if let chat { focus(session: chat.id) } else { show(workspace: id) }
    }
}

/// `kelp://` links (from a browser, a script, another app). Looking things up is free; adding a project asks first.
@MainActor
struct KelpLinks {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    func handle(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "workspace" where app.worktree(id) != nil: app.workbench.show(workspace: id)
        case "session" where app.session(id) != nil: app.workbench.focus(session: id)
        case "open":
            guard let path = q.first(where: { $0.name == "path" })?.value.map({ ($0 as NSString).expandingTildeInPath }),
                  FileManager.default.fileExists(atPath: path) else {
                Banner.show(String(localized: "Kelp can't find the file in that link."), style: .error)
                return
            }
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            if !dir.boolValue {
                let line = q.first { $0.name == "line" }?.value.flatMap(Int.init)
                let w = app.worktrees.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
                app.workbench.open(TabURI.file(path) + (line.map { "#L\($0)" } ?? ""), workspace: w?.id)
            } else if app.repos.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                app.workbench.addProject(path: path)   // already a project: just shows it
            } else {
                let a = NSAlert(); a.messageText = String(localized: "Add “\((path as NSString).lastPathComponent)” to Kelp?")
                a.informativeText = String(localized: "A link asked to open \(path) as a project.")
                a.addButton(withTitle: String(localized: "Add Project")); a.addButton(withTitle: String(localized: "Cancel"))
                Task { if await runSheet(a) == .alertFirstButtonReturn { app.workbench.addProject(path: path) } }
            }
        default: Banner.show(String(localized: "Kelp doesn't know the link \(url.absoluteString)."), style: .error)
        }
        NSApp.activate()
    }
}

/// IDE actions agents ask for through the daemon (`kelp open`, `kelp ui`). They never pull Kelp to the front, switch the
/// workspace on screen or take the keys unless asked (`--focus`): a tab for another workspace waits there.
@MainActor
struct UIRequests {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    func handle(_ e: UIEvent) {
        switch e.action {
        case "open":
            guard let uri = e.uri else { return }
            let split = e.split.flatMap(SplitDirection.init(rawValue:))
            let focus = e.focus == true
            if let w = e.worktreeId, w != app.workbench.workspaceId, !focus, app.workbench.workspaceId != nil {
                app.workbench.window?.editors.openInBackground(uri, workspace: w)
                return
            }
            // `kelp open`: the user's or their agent's own
            if TabURI.runs(uri) { app.workbench.runURI(uri, split: split, workspace: e.worktreeId, focus: focus) }
            else if focus { app.workbench.open(uri, split: split, workspace: e.worktreeId) }
            else { app.workbench.showAside(uri, split: split, workspace: e.worktreeId) }
            if focus { NSApp.activate() }
        case "command":
            guard let id = e.id else { return }
            if id == "extensions.reload" { app.extensions.reload(); return }
            if id == "window.shot", let w = app.workbench.window?.window, let path = e.args?["path"]?.string {
                AppDelegate.snap(w, to: path); return
            }
            guard let c = app.extensions.command(id) else { Banner.show(String(localized: "Unknown command \(id)"), style: .error); return }
            if case .object(let args)? = e.args { c.run(args) } else { c.run([:]) }
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
        let l = lines.map { $0.count == 1 ? ":\($0.lowerBound)" : ":\($0.lowerBound)-\($0.upperBound)" } ?? ""
        return IDE.escapedPath(rel) + l
    }

    /// The agent the user was last with in this workspace (never a plain terminal).
    package var targetAgent: Session? {
        let m = app, wid = app.workbench.workspaceId
        if let s = app.workbench.focusedSession.flatMap(m.session), s.agent != "shell", s.worktreeId == wid, s.status != .exited { return s }
        return m.sessions.last { $0.worktreeId == wid && $0.isChat && $0.status != .exited }
    }

    /// Types the reference into the agent's prompt without pressing Return, and shows the agent.
    package func sendToAgent(_ path: String, lines: ClosedRange<Int>? = nil) {
        guard let s = targetAgent else {
            Banner.show(String(localized: "No agent on this screen. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task { await app.call(SessionSend(id: s.id, text: reference(path, lines: lines) + " ", enter: false)) }
        app.workbench.focus(session: s.id)
    }

    /// Words into the agent's prompt, not sent: the user adds what to do with them.
    package func sendToAgent(text: String) {
        guard let s = targetAgent else {
            Banner.show(String(localized: "No agent on this screen. Start one with ⌥⌘T, then send again."), style: .error)
            return
        }
        Task { await app.call(SessionSend(id: s.id, text: text + " ", enter: false)) }
        app.workbench.focus(session: s.id)
    }

    package func copyWebLink(_ path: String, lines: ClosedRange<Int>? = nil) {
        Task {
            guard let url = await app.call(GitWebURL(path: path, start: lines?.lowerBound, end: lines?.upperBound)) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
            Banner.show(String(localized: "Link copied"))
        }
    }

    package func copyReference(_ path: String, lines: ClosedRange<Int>?) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reference(path, lines: lines), forType: .string)
    }
}

/// A git step that failed for a reason an agent can fix (hooks, a rejected push, conflicts): the error banner
/// offers to hand it to the workspace's agent, with the error, as a prompt waiting for Return.
@MainActor
package struct GitFix {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    package func offer(_ error: String, recipe: String, worktree wid: String, vars: [String: String] = [:]) {
        guard FileActions(app).targetAgent != nil else { Banner.show(error, style: .error); return }
        Banner.show(error, style: .error, action: (String(localized: "Ask Agent to Fix"), {
            send(recipe, worktree: wid, vars: vars.merging(["error": error]) { a, _ in a })
        }))
    }

    package func send(_ recipe: String, worktree wid: String, vars: [String: String]) {
        guard let s = FileActions(app).targetAgent else { return }
        Task { if await type(recipe, worktree: wid, vars: vars, into: s.id) { app.workbench.focus(session: s.id) } }
    }

    /// The recipe typed into the session, not sent: other people's text (errors, CI logs, review comments) waits for Return.
    package func type(_ recipe: String, worktree wid: String, vars: [String: String], into sid: String) async -> Bool {
        guard let text = await app.call(RecipeRender(id: wid, name: recipe, vars: vars)) else { return false }
        await app.call(SessionSend(id: sid, text: text, enter: false))
        return true
    }
}

@MainActor
package struct PRActions {
    let app: AppModel
    package init(_ app: AppModel) { self.app = app }

    /// Pushes and opens a PR; title and body come from the branch's commits.
    package func create(worktree wid: String) {
        let a = NSAlert(); a.messageText = String(localized: "Create a pull request?")
        a.informativeText = String(localized: "Pushes \(app.worktree(wid)?.branch ?? "the branch") and opens a PR titled from its commits.")
        a.addButton(withTitle: String(localized: "Create")); a.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(a) == .alertFirstButtonReturn else { return }
            guard let url = await app.call(GitHubPRCreate(worktreeId: wid))?.url else { return }
            Banner.show(url.isEmpty ? String(localized: "Pull request created") : String(localized: "Pull request created: \(url)"))
            if let u = URL(string: url), !url.isEmpty { app.workbench.open(u.absoluteString) }
        }
    }
}
