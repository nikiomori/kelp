import AppKit
import SwiftUI
import Core
import WorkbenchKit

extension SidebarController.Node {
    /// What muting this row names: a project's row also speaks for the workspace it stands for.
    var muteIds: [String] {
        switch kind {
        case .project(let id): [id] + (workspace.map { [$0] } ?? [])
        case .workspace(let id), .agent(let id): [id]
        case .section: []
        }
    }
}

/// What the sidebar's menus and keys do.
extension SidebarController {
    // MARK: actions

    /// What rows draw from the app's own state: a mute's bell, a project's colour.
    func followRowLooks() {
        track(owner: self) { [app] in app.mutes } changed: { [weak self] _ in self?.updateVisibleCells() }
        track(owner: self) { [app] in app.projectLook } changed: { [weak self] _ in self?.updateVisibleCells() }
    }

    func newChat(_ repo: String) { app.workbench.newChat(repo: repo) }

    /// The + on a project's row: the two things it can hold, with the keys that make them where you are.
    func addMenu(project id: String) -> NSMenu {
        let m = NSMenu(), app = app
        func show(_ i: NSMenuItem, key command: String) {
            guard let k = app.extensions.command(command)?.key.flatMap(KeySpec.init) else { return }
            i.keyEquivalent = k.key; i.keyEquivalentModifierMask = k.mods.flags
        }
        show(m.add(String(localized: "New Chat")) { app.workbench.newChat(repo: id) }, key: "workspace.new")
        show(m.add(String(localized: "New Group")) { app.workbench.newGroup(repo: id) }, key: "workspace.newGroup")
        if onThisMac(id) { show(m.add(String(localized: "New Chat on Branch")) { app.workbench.newBranch(repo: id) }, key: "workspace.newBranch") }
        return m
    }

    /// A remote project's branches would need its git on the host: there it works in its folder.
    private func onThisMac(_ project: String) -> Bool { app.repo(project).map { RemoteHost.of($0.path) == nil } ?? false }

    /// Where a chat can go: among the screens of its folder. One on a branch has its own files and stays.
    func moveItems(_ menu: NSMenu, chat sid: String) {
        let app = self.app
        guard let w = movable(sid), let r = app.repo(w.repoId) else { return }
        let own = mainWorkspace(of: r, among: app.worktrees), list = NSMenu()
        list.add(String(localized: "New Group")) { Task { await WorkspaceActions(app).newGroup(from: [sid]) } }
        if let own, own.id != w.id {
            list.add(String(localized: "Back to Project")) { Task { await WorkspaceActions(app).move([sid], to: own.id) } }
        }
        for g in app.workspaces(of: r) where g.path == r.path && g.id != w.id && g.id != own?.id {
            list.add(g.displayName) { Task { await WorkspaceActions(app).move([sid], to: g.id) } }
        }
        menu.setSubmenu(list, for: menu.addItem(withTitle: String(localized: "Move to"), action: nil, keyEquivalent: ""))
    }

    private func movable(_ sid: String) -> Worktree? {
        guard let w = app.session(sid).flatMap({ app.worktree($0.worktreeId) }), w.path == app.repo(w.repoId)?.path else { return nil }
        return w
    }
    func refreshCell(_ key: String) {
        guard let n = node(key) else { return }
        let row = outline.row(forItem: n)
        if row >= 0 { (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.update() }
    }

    /// Inline rename, like Finder: a workspace's name, or with `project` its project's own.
    func startRename(_ id: String, project: Bool = false) {
        guard let n = project ? node("p:" + id) : workspaceNode(id) else { return }
        let row = outline.row(forItem: n)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { return }
        renaming = (id, project)
        cell.beginEditing(delegate: self, project: project)
    }
    func controlTextDidEndEditing(_ n: Notification) {
        guard let (id, project) = renaming, let field = n.object as? NSTextField else { return }
        renaming = nil
        field.isEditable = false; field.drawsBackground = false
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if project {
            // An empty name gives the project its folder's back.
            if name != app.repo(id)?.name { Task { await app.call(RepoRename(id: id, name: name)) } } else { refreshCell("p:" + id) }
        } else if !name.isEmpty, name != app.worktree(id)?.displayName {
            Task { await app.call(WorktreeNote(id: id, note: name)) }
        } else if let n = workspaceNode(id) { refreshCell(n.key) }
    }

    func menuDidClose(_ menu: NSMenu) {
        outline.menuClosed()
        app.colorPreview = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = self.app
        menu.removeAllItems()
        card.close()
        guard let n = outline.item(atRow: outline.menuRow) as? Node else { return emptySpaceMenu(menu) }
        let m = app
        let picked = outline.selectedRowIndexes
        if picked.count > 1, picked.contains(outline.menuRow) {
            bulkMenu(menu, picked.compactMap { outline.item(atRow: $0) as? Node }); return
        }
        switch n.kind {
        case .project(let id):
            guard let r = m.repo(id) else { return }
            if !FileManager.default.fileExists(atPath: r.path) {
                menu.add(String(localized: "Locate…")) { WorkspaceActions(app).relocate(r) }
                menu.add(String(localized: "Remove from Kelp…")) { WorkspaceActions(app).removeProject(r) }
                return
            }
            if let w = app.rowBadges.folder(project: id) { MergedPR(app: app).addItems(to: menu, w) }
            menu.add(String(localized: "New Chat")) { [weak self] in self?.newChat(id) }
            menu.add(String(localized: "New Group")) { app.workbench.newGroup(repo: id) }
            if onThisMac(id) { menu.add(String(localized: "New Chat on Branch")) { app.workbench.newBranch(repo: id) } }
            menu.addItem(.separator())
            menu.add(String(localized: "Rename Project")) { [weak self] in self?.startRename(id, project: true) }
            colorItem(menu, id)
            muteItem(menu, n.muteIds)
            menu.addItem(.separator())
            WorkspaceActions.addLocate(to: menu, path: r.path)
            menu.addItem(.separator())
            if RemoteHost.of(r.path) == nil { menu.add(String(localized: "Remove Clean Worktrees…")) { WorkspaceActions(app).removeCleanWorktrees(r) } }
            menu.add(String(localized: "Remove Project…")) { WorkspaceActions(app).removeProject(r) }
        case .section: emptySpaceMenu(menu)
        case .workspace(let id): workspaceMenu(menu, id)
        case .agent(let sid):
            menu.add(String(localized: "Rename…")) { AgentActions(app).rename(sid) }
            menu.setSubmenu(AgentActions(app).handoffMenu(sid), for: menu.addItem(withTitle: String(localized: "Hand Off to"), action: nil, keyEquivalent: ""))
            menu.add(String(localized: "Copy Context")) { AgentActions(app).copyContext(sid) }
            menu.addItem(.separator())
            moveItems(menu, chat: sid)
            if m.session(sid)?.unread == false {
                menu.add(String(localized: "Mark as Unread")) { [app] in Task { await app.call(SessionMarkUnread(id: sid)) } }
            }
            muteItem(menu, n.muteIds)
            menu.addItem(.separator())
            menu.add(String(localized: "Restart")) { AgentActions(app).restart(sid) }
            menu.add(String(localized: "Stop…")) { AgentActions(app).stop([sid]) }
        }
    }

    /// Under the rows: the ways in, as the + shows them, and how the list looks.
    private func emptySpaceMenu(_ menu: NSMenu) {
        let app = self.app
        for id in ["workspace.addProject", "workspace.cloneRepository", "workspace.addRemote"] {
            if let c = app.extensions.command(id) { menu.add(c.title) { app.extensions.run(id) } }
        }
        menu.addItem(.separator())
        menu.addChoiceMenu("workbench.sidebar.order", app, title: String(localized: "Project Order"))
        menu.addChoiceMenu("workbench.sidebar.rowHeight", app, title: String(localized: "Row Height"))
        menu.addChoiceMenu("workbench.sidebar.projectColor", app, title: String(localized: "Project Color"))
        menu.addChoiceMenu("workbench.sidebar.agentIcons", app, title: String(localized: "Agent Icons"))
        menu.addToggle("workbench.sidebar.gitBadges", app, title: String(localized: "Changes and Pull Requests"))
        menu.addItem(.separator())
        menu.addToggle("workbench.sidebar.autoHide", app, title: String(localized: "Auto-Hide Sidebar"))
        menu.addSettingsLink(String(localized: "Sidebar Settings…"), section: "window", app)
    }

    /// A project's colour: a row of dots, or Color ▸ for VoiceOver and the keyboard, which reach only a menu's items.
    private func colorItem(_ menu: NSMenu, _ id: String) {
        let app = self.app, now = app.projectColors[id]
        func pick(_ c: ProjectColor?) { app.projectColors[id] = c }
        guard NSWorkspace.shared.isVoiceOverEnabled || NSApp.isFullKeyboardAccessEnabled else {
            let row = menu.addItem(withTitle: String(localized: "Color"), action: nil, keyEquivalent: "")
            row.view = ColorSwatches(chosen: now, previewing: { app.colorPreview = (id, $0) }, left: { app.colorPreview = nil }, pick: pick)
            return
        }
        let shades = NSMenu()
        shades.add(String(localized: "None")) { pick(nil) }.state = now == nil ? .on : .off
        shades.addItem(.separator())
        for c in ProjectColor.allCases {
            let i = shades.add(c.title) { pick(c) }
            i.show(c.dot)
            i.state = now == c ? .on : .off
        }
        menu.setSubmenu(shades, for: menu.addItem(withTitle: String(localized: "Color"), action: nil, keyEquivalent: ""))
    }

    /// Mute Notifications ▸ for how long, or Unmute once these are. A new mute goes on the first: the row itself.
    private func muteItem(_ menu: NSMenu, _ ids: [String]) {
        let app = self.app
        if app.mutedUntil(ids) != nil {
            menu.add(String(localized: "Unmute Notifications")) { app.mute(ids, until: nil) }
            return
        }
        let times = NSMenu()
        for (title, until) in Mutes.choices() { times.add(title) { app.mute(Array(ids.prefix(1)), until: until) } }
        menu.setSubmenu(times, for: menu.addItem(withTitle: String(localized: "Mute Notifications"), action: nil, keyEquivalent: ""))
    }

    /// A group's items on its heading.
    private func workspaceMenu(_ menu: NSMenu, _ id: String) {
        let app = self.app, m = app
        guard let w = m.worktree(id) else { return }
        let pinned = self.pinned.contains(id)
        menu.add(pinned ? String(localized: "Unpin") : String(localized: "Pin to Top")) { [weak self] in
            guard let self else { return }
            self.pinned = pinned ? self.pinned.filter { $0 != id } : self.pinned + [id]; refresh()
        }
        menu.add(String(localized: "Rename")) { [weak self] in self?.startRename(id) }
        menu.addItem(.separator())
        muteItem(menu, [id])
        WorkspaceActions.addLocate(to: menu, path: w.path)
        menu.addItem(.separator())
        if w.path == m.repo(w.repoId)?.path {
            // A desk: archiving pauses its agents and keeps its tabs (Window › Archived Workspaces brings it back);
            // with ⌥ the item closes it instead, ending its agents. The project's folder is untouched either way.
            menu.add(String(localized: "Archive")) { WorkspaceActions(app).archive(w) }
            let close = menu.add(String(localized: "Close Group")) { WorkspaceActions(app).close(w) }
            close.isAlternate = true
            close.keyEquivalentModifierMask = .option
        } else {
            menu.add(String(localized: "Archive")) { WorkspaceActions(app).archive(w) }
            menu.add(String(localized: "Delete Folder & Branch…")) { WorkspaceActions(app).delete(w) }
        }
    }
}

extension SidebarController {
    /// The menu for several selected rows: what applies to all of them.
    func bulkMenu(_ menu: NSMenu, _ nodes: [Node]) {
        let app = self.app
        let m = app
        let ws = nodes.compactMap { n -> Worktree? in
            if case .workspace(let id) = n.kind { m.worktree(id) } else { n.workspace.flatMap(m.worktree) }
        }
        let picked = nodes.compactMap { n -> String? in
            switch n.kind {
            case .agent(let id): id
            default: nil
            }
        }
        let inside = m.sessions.filter { s in ws.contains { $0.id == s.worktreeId } && s.isChat && s.status != .exited }.map(\.id)
        let agents = Array(Set(picked + inside))
        if agents.contains(where: { m.session($0)?.unread == true }) {
            menu.add(String(localized: "Mark as Read")) {
                for id in agents where m.session(id)?.unread == true { Task { await m.call(SessionMarkRead(id: id)) } }
            }
        }
        if !ws.isEmpty { menu.add(String(localized: "Close \(ws.count) Groups…")) { WorkspaceActions(app).close(ws) } }
        if picked.count > 1, Set(picked.compactMap { movable($0)?.repoId }).count == 1, picked.allSatisfy({ movable($0) != nil }) {
            menu.add(String(localized: "Move \(picked.count) Chats to New Group")) { Task { await WorkspaceActions(app).newGroup(from: picked) } }
        }
        if !picked.isEmpty {
            menu.addItem(.separator())
            menu.add(String(localized: "Stop \(Set(picked).count) Agents…")) { AgentActions(app).stop(Array(Set(picked))) }
        }
    }
}
