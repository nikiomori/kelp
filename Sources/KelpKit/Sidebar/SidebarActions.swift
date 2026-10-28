import AppKit
import SwiftUI
import Core
import WorkbenchKit

/// What the sidebar's menus and keys do.
extension SidebarController {
    // MARK: actions

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

    func menuDidClose(_ menu: NSMenu) { outline.menuClosed() }

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
            if n.workspace == nil {
                menu.add(String(localized: "Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)]) }
            }
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
            menu.addItem(.separator())
            menu.add(String(localized: "Stop")) { [app] in Task { await app.call(SessionKill(id: sid)) } }
        }
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
