import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

extension SidebarController.Node {
    /// What muting this row names: a project's row also speaks for the workspace it stands for.
    var muteIds: [String] {
        switch kind {
        case .project(let id): [id] + (workspace.map { [$0] } ?? [])
        case .workspace(let id), .agent(let id): [id]
        case .host, .parked: []
        }
    }
}

/// What the sidebar's menus and keys do.
extension SidebarController {
    // MARK: actions

    /// What the rows draw from the app's own state: a mute's bell and a project's colour.
    func followRowLooks() {
        track(owner: self) { [app] in
            app.arrangement.mutes
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
        track(owner: self) { [app] in
            app.arrangement.projectLook
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
    }

    func newChat(_ repo: String) { app.workbench.newChat(repo: repo) }

    /// Where a chat can go: among the screens of its folder. One on a branch has its own files and stays.
    func moveItems(_ menu: NSMenu, chat sid: String) {
        let app = self.app
        guard let worktree = movable(sid), let repo = app.repo(worktree.repoId) else { return }
        let own = mainWorkspace(of: repo, among: app.worktrees), list = NSMenu()
        list.add(String(localized: "New Group")) { Task { await WorkspaceActions(app).newGroup(from: [sid]) } }
        if let own, own.id != worktree.id {
            list.add(String(localized: "Back to Project")) {
                Task { await WorkspaceActions(app).move([sid], to: own.id) }
            }
        }
        for group in app.workspaces(of: repo)
        where group.path == repo.path && group.id != worktree.id && group.id != own?.id {
            list.add(group.displayName) { Task { await WorkspaceActions(app).move([sid], to: group.id) } }
        }
        menu.add(String(localized: "Move to"), submenu: list)
    }

    private func movable(_ sid: String) -> Worktree? {
        guard let worktree = app.session(sid).flatMap({ app.worktree($0.worktreeId) }),
            worktree.path == app.repo(worktree.repoId)?.path
        else { return nil }
        return worktree
    }
    func refreshCell(_ key: String) {
        guard let node = node(key) else { return }
        refreshCell(node)
    }
    private func refreshCell(_ node: Node) {
        let row = outline.row(forItem: node)
        if row >= 0 { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    /// What decides the rows a session has (`SidebarTree.build`): the same for all of a session's news but where it is,
    /// whose it is and whether it ended.
    static func place(_ session: Session) -> String {
        let shell = session.isTerminal ? "sh" : ""
        return [session.id, session.worktreeId ?? "", session.parent ?? "", shell, session.status == .exited ? "x" : ""]
            .joined(separator: "|")
    }

    /// Called when sessions changed without any row moving: only the rows showing them are updated (an agent's own row,
    /// its parent's row, and the rows above it, since its workspace and project sum up their agents), not every row in
    /// the list.
    func sessionsChanged(_ now: [Session]) {
        let changed = now.filter { shownBefore[$0.id] != $0 }
        shownBefore = Dictionary(now.map { ($0.id, $0) }) { _, last in last }
        guard !changed.isEmpty else { return }
        // A row's second line (what it asks) opens and closes it; the rows and cards below follow, on the scale.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.base)
            ctx.timingFunction = Motion.soft
            let rows = rows(showing: changed)
            rows.forEach(refreshCell)
            updateCard(only: rows)
        }
        updateHeaders()
    }
    /// The rows to show for these sessions: each agent's row, its parent's row, and the rows above them.
    func rows(showing sessions: [Session]) -> Set<Node> {
        var nodes: Set<Node> = []
        for s in sessions {
            for id in [s.id, s.parent].compactMap({ $0 }) { if let n = node("a:" + id) { nodes.insert(n) } }
            var above = s.worktreeId.flatMap(workspaceNode)
            while let n = above {
                nodes.insert(n)
                above = outline.parent(forItem: n) as? Node
            }
        }
        return nodes
    }

    /// Inline rename, like Finder: a workspace's name, or with `project` its project's own.
    func startRename(_ id: String, project: Bool = false) {
        guard let node = project ? node("p:" + id) : workspaceNode(id) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else {
            return
        }
        renaming = (id, project)
        cell.beginEditing(delegate: self, project: project)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let (id, project) = renaming, let field = notification.object as? NSTextField else { return }
        renaming = nil
        field.isEditable = false
        field.drawsBackground = false
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if project {
            // An empty name gives the project its folder's back.
            if name != app.repo(id)?.name {
                Task { await app.call(RepoRename(id: id, name: name)) }
            } else {
                refreshCell("p:" + id)
            }
        } else if !name.isEmpty, name != app.worktree(id)?.displayName {
            Task { await app.call(WorktreeNote(id: id, note: name)) }
        } else if let node = workspaceNode(id) {
            refreshCell(node.key)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        outline.menuClosed()
        app.arrangement.colorPreview = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = self.app
        menu.removeAllItems()
        card.close()
        guard let node = outline.item(atRow: outline.menuRow) as? Node else { return emptySpaceMenu(menu) }
        let model = app
        let picked = outline.selectedRowIndexes
        if picked.count > 1, picked.contains(outline.menuRow) {
            bulkMenu(menu, picked.compactMap { outline.item(atRow: $0) as? Node })
            return
        }
        switch node.kind {
        case .project(let id):
            guard let repo = model.repo(id) else { return }
            if NoProject.holds(repo) { return noProjectMenu(menu, repo, node) }
            if app.missingFolders.contains(repo.path) {   // as its row says: looked for off the main thread
                menu.add(String(localized: "Locate…")) { WorkspaceActions(app).relocate(repo) }
                menu.add(String(localized: "Remove from Kelp…")) { WorkspaceActions(app).removeProject(repo) }
                return
            }
            builtinItems(menu, node.kind)
            menu.add(String(localized: "New Chat")) { [weak self] in self?.newChat(id) }
            menu.add(String(localized: "New Group")) { app.workbench.newGroup(repo: id) }
            app.workbench.addWindowItems(to: menu, workspace: mainWorkspace(of: repo, among: model.worktrees)?.id)
            menu.addItem(.separator())
            menu.add(String(localized: "Rename Project")) { [weak self] in self?.startRename(id, project: true) }
            colorItem(menu, id)
            muteItem(menu, node.muteIds)
            WorkspaceActions(app).addDevContainer(to: menu, repo)
            menu.addItem(.separator())
            WorkspaceActions.addLocate(to: menu, path: repo.path)
            menu.addItem(.separator())
            if RemoteHost.of(repo.path) == nil {
                menu.add(String(localized: "Remove Clean Worktrees…")) {
                    WorkspaceActions(app).removeCleanWorktrees(repo)
                }
            }
            menu.add(String(localized: "Remove Project…")) { WorkspaceActions(app).removeProject(repo) }
        case .workspace(let id):
            builtinItems(menu, node.kind)
            workspaceMenu(menu, id)
        case .agent(let sid):
            builtinItems(menu, node.kind)
            menu.add(String(localized: "Rename…")) { AgentActions(app).rename(sid) }
            menu.add(String(localized: "Hand Off to"), submenu: AgentActions(app).handoffMenu(sid))
            AgentActions(app).addFork(to: menu, sid)
            AgentActions(app).addMove(to: menu, sid)
            menu.add(String(localized: "Copy Context")) { AgentActions(app).copyContext(sid) }
            menu.addItem(.separator())
            if let session = model.session(sid),
                NoProject.holds(model.worktree(session.worktreeId).flatMap { model.repo($0.repoId) })
            {
                WorkspaceActions.addLocate(to: menu, path: session.cwd)   // its own folder, where its results are
            } else {
                moveItems(menu, chat: sid)
            }
            if model.session(sid)?.unread == false {
                menu.add(String(localized: "Mark as Unread")) { [app] in
                    Task { await app.call(SessionMarkUnread(id: sid)) }
                }
            } else if model.session(sid)?.status == .done {   // finished and waiting to be seen: put away by hand, as a glance would
                menu.add(String(localized: "Mark as Read")) { [app] in Task { await app.call(SessionMarkRead(id: sid)) }
                }
            }
            muteItem(menu, node.muteIds)
            parkItem(menu, sid)
            menu.addItem(.separator())
            menu.add(String(localized: "Restart")) { AgentActions(app).restart(sid) }
            menu.add(String(localized: "Close Chat")) { app.workbench.closeChat(session: sid) }
        case .host:
            builtinItems(menu, node.kind)
            menu.addChoiceMenu(SettingKeys.serverLook, app, title: String(localized: "Servers"))
        case .parked: break
        }
    }

    /// What the built-ins add for the row (`Contributions.rowMenu`), at the top of its menu.
    private func builtinItems(_ menu: NSMenu, _ row: SidebarItem.Kind) {
        for add in app.extensions.all.rowMenu { add(row, menu) }
    }

    /// No Project's row menu: chats and its folder. There is nothing to rename, colour or remove, since the row is
    /// Kelp's own.
    private func noProjectMenu(_ menu: NSMenu, _ repo: Repo, _ node: Node) {
        let app = self.app
        menu.add(String(localized: "New Chat")) { [weak self] in self?.newChat(repo.id) }
        menu.add(String(localized: "New Chat in Folder…")) { app.noProject.newChat(inFolderOf: repo) }
        menu.addItem(.separator())
        muteItem(menu, node.muteIds)
        WorkspaceActions.addLocate(to: menu, path: repo.path)
    }

    /// Under the rows: the ways in, as the + shows them, and how the list looks.
    private func emptySpaceMenu(_ menu: NSMenu) {
        let app = self.app
        for id in ["workspace.addProject", "workspace.cloneRepository", "workspace.addRemote"] {
            if let command = app.extensions.command(id) { menu.add(command.title) { app.extensions.run(id) } }
        }
        menu.addItem(.separator())
        menu.addChoiceMenu(SettingKeys.sidebarOrder, app, title: String(localized: "Project Order"))
        menu.addChoiceMenu(SettingKeys.rowHeight, app, title: String(localized: "Row Height"))
        menu.addChoiceMenu(SettingKeys.projectColor, app, title: String(localized: "Project Color"))
        if app.extensions.all.servers != nil {   // no servers' cards to mark without the built-in that makes them
            menu.addChoiceMenu(SettingKeys.serverLook, app, title: String(localized: "Servers"))
        }
        menu.addChoiceMenu(SettingKeys.agentIcons, app, title: String(localized: "Agent Icons"))
        menu.addToggle(SettingKeys.gitBadges, app, title: String(localized: "Changes and Pull Requests"))
        menu.addItem(.separator())
        menu.addToggle(SettingKeys.sidebarAutoHide, app, title: String(localized: "Auto-Hide Sidebar"))
        menu.addSettingsLink(String(localized: "Sidebar Settings…"), section: "appearance", group: "Sidebar", app)
    }

    /// The menu items for a project's colour: a row of dots, or Color ▸ for VoiceOver and the keyboard, which can only
    /// reach a menu's items.
    private func colorItem(_ menu: NSMenu, _ id: String) {
        let app = self.app, now = app.arrangement.projectColors[id]
        let arrangement = app.arrangement
        menu.addColor(
            chosen: now, previewing: { arrangement.colorPreview = (id, $0) },
            left: { arrangement.colorPreview = nil }
        ) { arrangement.projectColors[id] = $0 }
    }

    /// Mute Notifications ▸ for how long, or Unmute once these are. A new mute goes on the first: the row itself.
    private func muteItem(_ menu: NSMenu, _ ids: [String]) {
        let app = self.app
        if app.arrangement.mutedUntil(ids) != nil {
            menu.add(String(localized: "Unmute Notifications")) { app.arrangement.mute(ids, until: nil) }
            return
        }
        let times = NSMenu()
        for (title, until) in Mutes.choices() {
            times.add(title) { app.arrangement.mute(Array(ids.prefix(1)), until: until) }
        }
        menu.add(String(localized: "Mute Notifications"), submenu: times)
    }

    /// Park ▸ for how long, or Unpark once it is.
    private func parkItem(_ menu: NSMenu, _ sid: String) {
        let app = self.app
        if app.arrangement.isParked(sid) {
            menu.add(String(localized: "Unpark")) { app.arrangement.unpark(sid) }
            return
        }
        let times = NSMenu()
        for (title, until) in Parking.choices() { times.add(title) { app.arrangement.park(sid, until: until) } }
        menu.add(String(localized: "Park"), submenu: times)
    }

    /// A group's items on its heading.
    private func workspaceMenu(_ menu: NSMenu, _ id: String) {
        let app = self.app, model = app
        guard let worktree = model.worktree(id) else { return }
        menu.add(String(localized: "Rename")) { [weak self] in self?.startRename(id) }
        app.workbench.addWindowItems(to: menu, workspace: id)
        menu.addItem(.separator())
        muteItem(menu, [id])
        WorkspaceActions.addLocate(to: menu, path: worktree.path)
        menu.addItem(.separator())
        if worktree.path == model.repo(worktree.repoId)?.path {
            // A workspace: archiving pauses its agents and keeps its tabs (Window › Archived Workspaces brings it back);
            // with ⌥ the item closes it instead, ending its agents. The project's folder is untouched either way.
            menu.add(String(localized: "Archive")) { WorkspaceActions(app).archive(worktree) }
            let close = menu.add(String(localized: "Close Group")) { WorkspaceActions(app).close(worktree) }
            close.isAlternate = true
            close.keyEquivalentModifierMask = .option
        } else {
            menu.add(String(localized: "Archive")) { WorkspaceActions(app).archive(worktree) }
            menu.add(String(localized: "Delete Folder & Branch…")) { WorkspaceActions(app).delete(worktree) }
        }
    }
}

extension SidebarController {
    /// The menu for several selected rows: what applies to all of them.
    func bulkMenu(_ menu: NSMenu, _ nodes: [Node]) {
        let app = self.app
        let model = app
        let ws = nodes.compactMap { node -> Worktree? in
            if case .workspace(let id) = node.kind {
                model.worktree(id)
            } else {
                node.workspace.flatMap(model.worktree)
            }
        }
        let picked = nodes.compactMap { node -> String? in
            switch node.kind {
            case .agent(let id): id
            default: nil
            }
        }
        let inside = model.sessions.filter { session in
            ws.contains { $0.id == session.worktreeId } && session.isChat && session.status != .exited
        }
        .map(\.id)
        let agents = Array(Set(picked + inside))
        if agents.contains(where: { model.session($0)?.unread == true }) {
            menu.add(String(localized: "Mark as Read")) {
                for id in agents where model.session(id)?.unread == true {
                    Task { await model.call(SessionMarkRead(id: id)) }
                }
            }
        }
        if !ws.isEmpty { menu.add(String(localized: "Close \(ws.count) Groups…")) { WorkspaceActions(app).close(ws) } }
        if picked.count > 1, Set(picked.compactMap { movable($0)?.repoId }).count == 1,
            picked.allSatisfy({ movable($0) != nil })
        {
            menu.add(String(localized: "Move \(picked.count) Chats to New Group")) {
                Task { await WorkspaceActions(app).newGroup(from: picked) }
            }
        }
        if !picked.isEmpty {
            menu.addItem(.separator())
            menu.add(String(localized: "Stop \(Set(picked).count) Agents…")) {
                AgentActions(app).stop(Array(Set(picked)))
            }
        }
    }
}
