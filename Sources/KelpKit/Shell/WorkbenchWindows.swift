import AppKit
import Core

/// Groups in windows of their own (`OwnWindow`). The window with the keyboard decides which workspace is on screen (the
/// main window's, or the group's whose window has it), and the sidebar, the inspector and every command follow it.
@MainActor
extension Workbench {
    func inOwnWindow(_ id: String?) -> Bool { window?.editors.ownWindow(id) != nil }

    /// Shown somewhere: in the main window (not under a page) or in a window of its own.
    func isOnScreen(_ id: String) -> Bool {
        id == workspaceId || id == mainWorkspaceId && page == nil || inOwnWindow(id)
    }

    /// The group's row: into a window of its own, or back into the main window. Kept across launches.
    func toggleOwnWindow(_ id: String) {
        if inOwnWindow(id) { returnToMain(id) } else { moveToOwnWindow(id) }
    }

    /// Adds the window items to a group heading's menu, and to a project row's menu (for the project's own screen):
    /// "Open in Own Window" (ticked while the group is in its own window), and keeping its layout as a template.
    func addWindowItems(to menu: NSMenu, workspace id: String?) {
        guard let id else { return }
        let app = self.app
        menu.add(String(localized: "Open in Own Window")) { app.workbench.toggleOwnWindow(id) }.state =
            inOwnWindow(id) ? .on : .off
        menu.add(String(localized: "Save Layout as Template…")) {
            Task { await LayoutTemplates(app: app).save(from: id) }
        }
    }

    func moveToOwnWindow(_ id: String) {
        guard let editors = window?.editors, app.worktree(id) != nil else { return }
        // The main window shows what was there before, rather than nothing.
        let next = recentWorkspaces.first { $0 != id && !inOwnWindow($0) && app.worktree($0) != nil }
        let fromMain = mainWorkspaceId == id
        editors.moveToOwnWindow(id, next: fromMain ? next : nil)
        // A server's page over it went with it (the main window shows `next`): its row opens it again.
        if fromMain { page = nil }
        saveOwnWindows()
        ownWindowBecameKey(id)
    }

    /// The group's own window closed: the group, with all its tabs, is in the main window, in front.
    func returnToMain(_ id: String) {
        window?.editors.leaveOwnWindow(id)
        saveOwnWindows()
        show(workspace: id)
        bringToFront()
    }

    func ownWindowBecameKey(_ id: String) {
        window?.editors.becameKey(id)
        guard workspaceId != id else { return }
        workspaceId = id
        noteShown()
        history.visit(id)
    }

    /// Called when the main window got the keyboard back from a group's own window, or when that group went away with
    /// its window (removed elsewhere: `EditorHost.refresh`). The main window's workspace is then the one on screen.
    func mainWindowBecameKey() {
        guard inOwnWindow(workspaceId) || app.worktree(workspaceId) == nil else { return }
        window?.editors.becameKey(nil)
        guard let main = mainWorkspaceId else { return }
        workspaceId = main
        noteShown()
        history.visit(main)
    }

    /// At launch, after the main window shows its workspace: the groups that were in windows of their own.
    func reopenOwnWindows() {
        for id in app.uiState.strings(Self.ownWindowsKey) where app.worktree(id) != nil { moveToOwnWindow(id) }
        for uri in app.uiState.strings(Self.pageWindowsKey) { openInOwnWindow(uri) }
    }

    /// Opens a server's or machine's page (`host:`, `vm:`) in a window of its own, from its row's menu; if the page is
    /// already in one, that window comes to the front. The window is kept across launches, and a server's page
    /// reconnects then the same way it does when opened by hand.
    package func openInOwnWindow(_ uri: String) {
        guard !raiseOwnWindow(uri), let page = app.extensions.tabProvider(for: uri)?.make(uri) else { return }
        let app = self.app
        let made = OwnWindow(app: app, name: "page." + uri, content: page.view, beside: window?.window) {
            page.title
        } closed: {
            Task {
                guard await page.close() else { return }
                app.workbench.pageWindows.removeValue(forKey: uri)?.close()
                app.workbench.savePageWindows()
            }
        }
        pageWindows[uri] = made
        savePageWindows()
        made.showWindow(nil)
        page.focus()
    }

    /// What's asked for is in a window of its own: that window comes to the front instead.
    func raiseOwnWindow(_ uri: String) -> Bool {
        guard let made = pageWindows[uri] else { return false }
        made.showWindow(nil)
        return true
    }

    /// The page's own window that has the keys: no editor area has the keyboard then (`editor`), and ⌘W closes it.
    var keyPageWindow: OwnWindow? { pageWindows.values.first(where: \.hasKeys) }

    /// Called when one of Kelp's windows was covered, minimized or seen again. Kelp counts as away (`AppModel.setAway`)
    /// only while no window that shows a workspace or a page is seen: the main window, a group's own window, or a
    /// server's or machine's page window.
    /// `seen` lets a test say what is seen (its windows are never on screen).
    func sightChanged(seen: (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }) {
        let groups = window?.editors.ownWindowIds.map { window?.editors.ownWindow($0) } ?? []
        let places = [window?.window] + groups + pageWindows.values.map(\.window)
        app.setAway(!places.contains { $0.map(seen) ?? false })
    }

    /// The editor area someone can be reading: the one with the keyboard, while the window it's in (the main one, or
    /// its group's own) is the key window and seen. `front`: a test's own (its windows never are).
    func editorInFront(
        _ front: (NSWindow) -> Bool = { $0.isKeyWindow && $0.occlusionState.contains(.visible) }
    ) -> EditorArea? {
        activeWindow.map(front) == true ? editor : nil
    }

    private static let pageWindowsKey = "workbench.pageWindows"
    private func savePageWindows() {
        app.uiState[Self.pageWindowsKey] = .array(pageWindows.keys.sorted().map(JSONValue.string))
    }

    private static let ownWindowsKey = "workbench.ownWindows"
    private func saveOwnWindows() {
        app.uiState[Self.ownWindowsKey] = .array((window?.editors.ownWindowIds ?? []).sorted().map(JSONValue.string))
    }
}
