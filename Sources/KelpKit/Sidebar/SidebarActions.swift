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

    func newWorkspace(_ repo: String) { app.workbench.newWorkspace(repo: repo) }
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
        guard let n = outline.item(atRow: outline.menuRow) as? Node else { return }
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
            // Standing for its only workspace: that workspace's items first, then the project's.
            if let w = n.workspace { workspaceMenu(menu, w, onProject: true); menu.addItem(.separator()) }
            menu.add(String(localized: "New Workspace")) { [weak self] in self?.newWorkspace(id) }
            menu.add(String(localized: "Rename Project")) { [weak self] in self?.startRename(id, project: true) }
            colorItem(menu, id)
            if n.workspace == nil {
                menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            }
            muteItem(menu, n.muteIds)
            menu.addItem(.separator())
            if RemoteHost.of(r.path) == nil { menu.add(String(localized: "Remove Clean Worktrees…")) { WorkspaceActions(app).removeCleanWorktrees(r) } }
            menu.add(String(localized: "Remove Project…")) { WorkspaceActions(app).removeProject(r) }
        case .section: return
        case .workspace(let id): workspaceMenu(menu, id)
        case .agent(let sid):
            menu.add(String(localized: "Show")) { app.workbench.focus(session: sid) }
            menu.add(String(localized: "Rename…")) { AgentActions(app).rename(sid) }
            menu.add(String(localized: "Restart")) { AgentActions(app).restart(sid) }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Context")) { AgentActions(app).copyContext(sid) }
            menu.setSubmenu(AgentActions(app).handoffMenu(sid), for: menu.addItem(withTitle: String(localized: "Hand Off to"), action: nil, keyEquivalent: ""))
            if m.session(sid)?.unread == false {
                menu.add(String(localized: "Mark as Unread")) { [app] in Task { await app.call(SessionMarkUnread(id: sid)) } }
            }
            muteItem(menu, n.muteIds)
            menu.addItem(.separator())
            menu.add(String(localized: "Stop")) { [app] in Task { await app.call(SessionKill(id: sid)) } }
        }
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

    /// A workspace's items, on its row or on its project's when that stands for it (`onProject`: its Rename says whose).
    private func workspaceMenu(_ menu: NSMenu, _ id: String, onProject: Bool = false) {
        let app = self.app, m = app
        guard let w = m.worktree(id) else { return }
        let pinned = self.pinned.contains(id)
        menu.add(pinned ? String(localized: "Unpin") : String(localized: "Pin to Top")) { [weak self] in
            guard let self else { return }
            self.pinned = pinned ? self.pinned.filter { $0 != id } : self.pinned + [id]; refresh()
        }
        menu.add(onProject ? String(localized: "Rename Workspace") : String(localized: "Rename")) { [weak self] in self?.startRename(id) }
        menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
        menu.add(String(localized: "Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(w.path, forType: .string) }
        WorkspaceActions.addOpenIn(to: menu, path: w.path)
        if !onProject { muteItem(menu, [id]) }   // the project's own item speaks for it
        menu.addItem(.separator())
        if w.path == m.repo(w.repoId)?.path {
            // A desk: archiving pauses its agents and keeps its tabs (Window › Archived Workspaces brings it back);
            // with ⌥ the item closes it instead, ending its agents. The project's folder is untouched either way.
            let more = m.worktrees.filter { $0.repoId == w.repoId && $0.path == w.path && !$0.archived }.count > 1
            let archive = menu.add(String(localized: "Archive")) { WorkspaceActions(app).archive(w) }
            archive.isEnabled = more
            let close = menu.add(String(localized: "Close Workspace")) { WorkspaceActions(app).close(w) }
            close.isAlternate = true
            close.keyEquivalentModifierMask = .option
            close.isEnabled = more
        } else {
            menu.add(String(localized: "Archive")) { WorkspaceActions(app).archive(w) }
            menu.add(String(localized: "Delete Workspace & Branch…")) { WorkspaceActions(app).delete(w) }
        }
    }
}
