import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Entry points everything uses to act on the window: open URIs, switch workspaces, focus agents.
@MainActor
extension Workbench {
    /// Every unsaved file in the app, which means those in the main window's loaded workspaces.
    package var editedFiles: [SavableTab] { window?.editors.editedFiles ?? [] }
    /// The editor area that has the keyboard, which is the one of the workspace on screen. It is nil while a page is on
    /// screen or a page's own window has the keyboard. Then whatever acts on tabs waits until a workspace is back,
    /// instead of reaching into another window.
    var editor: EditorArea? {
        keyPageWindow == nil && (page == nil || inOwnWindow(workspaceId)) ? window?.editors.current : nil
    }
    /// What starts agents and terminals in the workspace on screen. It is nil when no workspace (or a page) is on
    /// screen.
    package var starter: SessionStarter? { editor?.starter }
    /// What starts agents and terminals for an action that adds a tab (a command in a terminal, an agent). A page on
    /// screen gives way to the workspace, as for `open`.
    package var starterForNewTab: SessionStarter? { area(nil)?.starter }
    /// Returns `create` set to the size its terminal will have, for a session that `starter` doesn't start (its tab is
    /// opened by hand, hidden, or in another workspace). A first screen drawn for another width leaves zsh's stray "%"
    /// line.
    package func sized<M: StartsSized>(_ create: M, split: SplitDirection? = nil) -> M {
        if let starter { return starter.sized(create, split: split) }
        var create = create
        create.cols = terminalGrid?.cols
        create.rows = terminalGrid?.rows
        return create
    }

    // What a built-in may do to the tabs of the workspace on screen (it never gets the editor area itself).
    /// The built content of the tab with focus there.
    package var focusedContent: TabContent? { editor?.focusedContent }
    /// The URIs of every tab open in the workspace on screen.
    package var tabURIs: [String] { editor?.layout.allTabs.map(\.uri) ?? [] }
    /// Shows `new` in the tab that shows `old` there (for an untitled file saved under a name).
    package func replace(_ old: String, with new: String) { editor?.replace(old, with: new) }
    /// Gives the keyboard back to the tab in front there.
    package func focusTab() { editor?.focusSelected() }
    /// Moves the focused tab into a new pane to the right or below. It beeps when no workspace is on screen.
    package func split(_ direction: SplitDirection) {
        guard let editor else { return NSSound.beep() }
        editor.splitFocused(direction)
    }
    /// Puts agents side by side, or every tab in one pane (⌃⌘T). It beeps when no workspace is on screen.
    package func toggleSideBySide() {
        guard let editor else { return NSSound.beep() }
        editor.toggleSideBySide()
    }

    package func show(workspace id: String) { show(workspace: id, remember: true) }

    private func show(workspace id: String, remember: Bool) {
        let own = inOwnWindow(id)
        guard workspaceId != id || page != nil && !own || window?.editors.current?.workspaceId != id else { return }
        let left = workspaceId
        if !own { page = nil }
        workspaceId = id
        noteShown()
        if remember { history.visit(id) }
        window?.showWorkspace(id)
        if let left, left != id, !isOnScreen(left) { WorkspaceActions(app).left(left) }
    }

    /// Shows a page in place of the workspace (`page`).
    func show(page uri: String) {
        guard !raiseOwnWindow(uri), page != uri, window?.showPage(uri) == true else { return }
        page = uri
        noteShown()
    }

    /// ⌃⌘← / ⌃⌘→ go to the workspace shown before / after this one (closed ones are skipped).
    /// Returns the places Back (-1) or Forward (1) can reach, nearest first: where each is in the history, and its
    /// name.
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

    /// Where Back (-1) or Forward (1) would go. It is nil when there is nothing that way, and the title bar's arrows
    /// grey out.
    func visit(_ step: Int) -> Int? {
        history.target(step, current: workspaceId) { app.worktree($0) != nil }
    }

    package func open(_ uri: String, split: SplitDirection? = nil, workspace: String? = nil, focus: Bool = true) {
        if raiseOwnWindow(uri) { return }
        area(workspace)?.open(uri, split: split, focus: focus)
    }

    /// Opens a tab in a workspace that isn't on screen, without showing it (for a run started there).
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

    /// For Restart, the new session takes the old session's tab in the workspace it belongs to, which may not be the
    /// one on screen (Restart from the sidebar).
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
        // Opening a finished agent counts as reading it. A question stays marked until it's answered (typing clears
        // it).
        if session.unread, session.status == .done { Task { await app.call(SessionMarkRead(id: id)) } }
    }

    /// Whether the user is looking at the agent's tab, so no notification is needed for it.
    func isViewing(session id: String) -> Bool {
        activeWindow?.isKeyWindow == true && editor?.layout.focusedGroup?.selectedTab?.uri == TabURI.session(id)
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

    /// Closes the chat, wherever it is. The screen you're on stays.
    func closeChat(session id: String) {
        if let wid = app.session(id)?.worktreeId { window?.editors.closeChat(id, workspace: wid) }
    }

    /// Shows Open Quickly (⌘P), with the field starting with `text` (":" for Go to Line).
    package func openQuickly(text: String = "") { app.quickOpen.show(commandsOnly: false, text: text) }
    /// Lists the tmux sessions to attach to, where the palette shows.
    package func showTmuxSessions() { app.quickOpen.showTmux() }
    /// Shows a built-in's own list in the palette (Open Database). `rows` makes the list's rows from what's typed.
    package func showList(
        _ placeholder: String, keys: String, rows: @escaping @MainActor (String) async -> [QuickItem]
    ) { app.quickOpen.showList(placeholder, keys: keys, rows: rows) }

    /// ⇧⌘U shows the next agent that asked something or finished, wherever it is.
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

    /// The sessions the sidebar lists. A session a built-in keeps out of sight (a run hidden in the Run menu) isn't
    /// listed.
    var shownSessions: [Session] {
        let hidden = keptHidden, inTab = Set(app.uiState.strings(Session.inTabKey))
        return app.sessions.filter { !hidden.contains($0.id) && !isOnLine($0, inTab: inTab) }
    }
    /// Whether a session has no tab of its own. That is a session a built-in keeps out of sight (a run put away in the
    /// Run menu), or a command its agent's line shows.
    package func isHidden(_ sid: String) -> Bool {
        keptHidden.contains(sid) || app.session(sid).map { isOnLine($0) } == true
    }
    private var keptHidden: Set<String> {
        app.extensions.all.sessionHidden.reduce(into: []) { $0.formUnion($1()) }
    }
    /// The commands shown on the line of agent `id` (`isOnLine`). They come from an index, because each agent's bar
    /// asks on every session's news.
    package func onLine(of id: String) -> [Session] {
        let mine = app.started(by: id)
        guard !mine.isEmpty else { return [] }   // no UI state read for an agent that started none
        let inTab = Set(app.uiState.strings(Session.inTabKey))
        return mine.filter { isOnLine($0, inTab: inTab) }
    }
    /// Whether the session is a command its agent's line shows, and not moved to a tab of its own (`openInTab`).
    func isOnLine(_ session: Session, inTab: Set<String>? = nil) -> Bool {
        app.owner(of: session) != nil
            && !(inTab ?? Set(app.uiState.strings(Session.inTabKey))).contains(session.id)
    }
    /// Moves a command off its agent's line into a tab like any other. It stays a tab, and only live commands are kept
    /// in the list.
    package func openInTab(_ sid: String) {
        let live = app.uiState.strings(Session.inTabKey).filter {
            app.session($0).map { $0.status != .exited } ?? false
        }
        app.uiState[Session.inTabKey] = .array((live.filter { $0 != sid } + [sid]).map(JSONValue.string))
        open(TabURI.session(sid), workspace: app.session(sid)?.worktreeId)
    }

    func addProject() {
        // A new folder made here becomes a new project (Kelp asks whether to `git init` it). Clone and SSH are their
        // own commands.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a project folder, or make a new one")
        panel.prompt = String(localized: "Add Project")
        // A sheet on the window, not an app-modal panel that stops everything else.
        Task {
            guard await runSheet(panel) == .OK, let url = panel.url else { return }
            addProject(path: url.path)
        }
    }

    /// Shows the project for a folder dropped on the Dock icon or the sidebar, opened with `open -a Kelp .`, or picked
    /// in Add Project. A new project is added first, and a folder inside a repository adds the repository.
    func addProject(path: String) {
        Task {
            let model = app
            await model.waitForConnection()   // in case Kelp was opened with the folder at launch
            guard let rid = await repoAdd(path, model)?.id else { return }
            let ws = model.repo(rid).map(model.workspaces(of:)) ?? []
            if let screen = ws.first(where: { $0.id == workspaceId }) ?? ws.first { show(workspace: screen.id) }
        }
    }

    /// Adds the folder's project. For a folder outside any repository, Kelp first asks whether to make it one
    /// (`git init`) or add it as it is.
    private func repoAdd(_ path: String, _ model: AppModel) async -> Repo? {
        do { return try await model.get(RepoAdd(path: path)) } catch let error as RPCError
            where error.code == RepoAdd.notARepository.code
        {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\((path as NSString).lastPathComponent)” isn’t a Git repository")
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

    /// Opens files and folders from Finder (dropped on the window or the Dock icon, or `open -a Kelp <path>`). A folder
    /// becomes a project, and a file opens as a tab (with `open`, in that editor area, or else wherever ⌘O would).
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
}
