import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

extension SidebarController.Node {
    /// The ids that muting this row mutes. A project's row also mutes the workspace it stands for.
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

    /// Follows what the rows draw from the app's own state: the bell of a mute and a project's colour.
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

    /// Adds the places a chat can move to: the screens of its folder. A chat on a branch has its own files, so it
    /// stays.
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

    /// The part of a session that decides its rows (`SidebarTree.build`). It stays the same for all of a session's news
    /// except where the session is, whose child it is, and whether it ended.
    static func place(_ session: Session) -> String {
        let shell = session.isTerminal ? "sh" : ""
        return [session.id, session.worktreeId ?? "", session.parent ?? "", shell, session.status == .exited ? "x" : ""]
            .joined(separator: "|")
    }

    /// Called when sessions changed without any row moving. Only the rows showing those sessions are updated, not every
    /// row in the list: an agent's own row, its parent's row, and the rows above it, since the workspace and project
    /// sum up their agents.
    func sessionsChanged(_ now: [Session]) {
        let changed = now.filter { shownBefore[$0.id] != $0 }
        shownBefore = Dictionary(now.map { ($0.id, $0) }) { _, last in last }
        guard !changed.isEmpty else { return }
        // A row's second line (what the agent asks) opens and closes the row, and the rows and cards below follow at
        // the same pace.
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

    /// Starts an inline rename, like Finder's, of a workspace's name, or with `project` of the project's own name.
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
            // An empty name gives the project back the name of its folder.
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
        let picked = outline.selectedRowIndexes
        if picked.count > 1, picked.contains(outline.menuRow) {
            bulkMenu(menu, picked.compactMap { outline.item(atRow: $0) as? Node })
            return
        }
        switch node.kind {
        case .project(let id):
            guard let repo = app.repo(id) else { return }
            if NoProject.holds(repo) { return noProjectMenu(menu, repo, node) }
            if app.missingFolders.contains(repo.path) {   // as the row says; checked off the main thread
                menu.add(String(localized: "Locate…")) { WorkspaceActions(app).relocate(repo) }
                menu.add(String(localized: "Remove from Kelp…")) { WorkspaceActions(app).removeProject(repo) }
                return
            }
            builtinItems(menu, node.kind)
            menu.add(String(localized: "New Chat")) { [weak self] in self?.newChat(id) }
            menu.add(String(localized: "New Group")) { app.workbench.newGroup(repo: id) }
            app.workbench.addWindowItems(to: menu, workspace: mainWorkspace(of: repo, among: app.worktrees)?.id)
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
            if let session = app.session(sid),
                NoProject.holds(app.worktree(session.worktreeId).flatMap { app.repo($0.repoId) })
            {
                WorkspaceActions.addLocate(to: menu, path: session.cwd)   // the chat's own folder, with its results
            } else {
                moveItems(menu, chat: sid)
            }
            if app.session(sid)?.unread == false {
                menu.add(String(localized: "Mark as Unread")) { [app] in
                    Task { await app.call(SessionMarkUnread(id: sid)) }
                }
            } else if app.session(sid)?.status == .done {
                // A finished chat waits to be seen. This marks it read by hand, as looking at it would.
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

    /// Adds what the built-ins offer for the row (`Contributions.rowMenu`) at the top of the row's menu.
    private func builtinItems(_ menu: NSMenu, _ row: SidebarItem.Kind) {
        for add in app.extensions.all.rowMenu { add(row, menu) }
    }

    /// The menu of the No Project row: chats and the row's folder. There is nothing to rename, colour or remove,
    /// because the row is Kelp's own.
    private func noProjectMenu(_ menu: NSMenu, _ repo: Repo, _ node: Node) {
        let app = self.app
        menu.add(String(localized: "New Chat")) { [weak self] in self?.newChat(repo.id) }
        menu.add(String(localized: "New Chat in Folder…")) { app.noProject.newChat(inFolderOf: repo) }
        menu.addItem(.separator())
        muteItem(menu, node.muteIds)
        WorkspaceActions.addLocate(to: menu, path: repo.path)
    }

    /// The menu for the empty space under the rows: the ways to add a project, as the + shows them, and how the list
    /// looks.
    private func emptySpaceMenu(_ menu: NSMenu) {
        let app = self.app
        for id in ["workspace.addProject", "workspace.cloneRepository", "workspace.addRemote"] {
            if let command = app.extensions.command(id) { menu.add(command.title) { app.extensions.run(id) } }
        }
        menu.addItem(.separator())
        menu.addChoiceMenu(SettingKeys.sidebarOrder, app, title: String(localized: "Project Order"))
        menu.addChoiceMenu(SettingKeys.rowHeight, app, title: String(localized: "Row Height"))
        menu.addChoiceMenu(SettingKeys.projectColor, app, title: String(localized: "Project Color"))
        if app.extensions.all.servers != nil {   // without the built-in that makes them, there are no server cards
            menu.addChoiceMenu(SettingKeys.serverLook, app, title: String(localized: "Servers"))
        }
        menu.addChoiceMenu(SettingKeys.agentIcons, app, title: String(localized: "Agent Icons"))
        menu.addToggle(SettingKeys.gitBadges, app, title: String(localized: "Changes and Pull Requests"))
        menu.addItem(.separator())
        menu.addToggle(SettingKeys.sidebarAutoHide, app, title: String(localized: "Auto-Hide Sidebar"))
        menu.addSettingsLink(String(localized: "Sidebar Settings…"), section: "appearance", group: "Sidebar", app)
    }

    /// The menu items for a project's colour: a row of dots, or Color ▸ for VoiceOver and the keyboard, which can only
    /// reach the items of a menu.
    private func colorItem(_ menu: NSMenu, _ id: String) {
        let app = self.app, now = app.arrangement.projectColors[id]
        let arrangement = app.arrangement
        menu.addColor(
            chosen: now, previewing: { arrangement.colorPreview = (id, $0) },
            left: { arrangement.colorPreview = nil }
        ) { arrangement.projectColors[id] = $0 }
    }

    /// Adds Mute Notifications ▸ with how long to mute, or Unmute once the ids are muted. A new mute goes on the first
    /// id, which is the row itself.
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

    /// Adds Park ▸ with how long to park the chat, or Unpark once it is parked.
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

    /// The items in the menu on a group's heading.
    private func workspaceMenu(_ menu: NSMenu, _ id: String) {
        let app = self.app
        guard let worktree = app.worktree(id) else { return }
        menu.add(String(localized: "Rename")) { [weak self] in self?.startRename(id) }
        app.workbench.addWindowItems(to: menu, workspace: id)
        menu.addItem(.separator())
        muteItem(menu, [id])
        WorkspaceActions.addLocate(to: menu, path: worktree.path)
        menu.addItem(.separator())
        if worktree.path == app.repo(worktree.repoId)?.path {
            // For a workspace, Archive pauses its agents and keeps its tabs (Window › Archived Workspaces brings it
            // back). With ⌥ the item closes it instead, which ends its agents. The project's folder is untouched
            // either way.
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
    /// The menu for several selected rows, with what applies to all of them.
    func bulkMenu(_ menu: NSMenu, _ nodes: [Node]) {
        let app = self.app
        let ws = nodes.compactMap { node -> Worktree? in
            if case .workspace(let id) = node.kind {
                app.worktree(id)
            } else {
                node.workspace.flatMap(app.worktree)
            }
        }
        let picked = nodes.compactMap { node -> String? in
            switch node.kind {
            case .agent(let id): id
            default: nil
            }
        }
        let inside = app.sessions.filter { session in
            ws.contains { $0.id == session.worktreeId } && session.isChat && session.status != .exited
        }
        .map(\.id)
        let agents = Array(Set(picked + inside))
        if agents.contains(where: { app.session($0)?.unread == true }) {
            menu.add(String(localized: "Mark as Read")) {
                for id in agents where app.session(id)?.unread == true {
                    Task { await app.call(SessionMarkRead(id: id)) }
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
