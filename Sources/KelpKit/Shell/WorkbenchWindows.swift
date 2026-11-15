import AppKit
import Core

/// Groups in windows of their own (`OwnWindow`): the keys say which workspace is on screen — the main window's or
/// the group's whose window has them — and the sidebar, the inspector and every command follow.
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

    /// A group's heading's menu and its project's row's (for the project's own screen): its own window (ticked while
    /// it's in one), and its layout kept as a template.
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
        editors.moveToOwnWindow(id, next: mainWorkspaceId == id ? next : nil)
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

    /// The main window got the keys back from a group's own window: its workspace is the one on screen.
    func mainWindowBecameKey() {
        guard inOwnWindow(workspaceId) else { return }
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

    /// A server's or a machine's page (`host:`, `vm:`) in a window of its own, from its row's menu; already in one, that
    /// window comes to the front. Kept across launches, where a server's page connects as it does when opened by hand.
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

    private static let pageWindowsKey = "workbench.pageWindows"
    private func savePageWindows() {
        app.uiState[Self.pageWindowsKey] = .array(pageWindows.keys.sorted().map(JSONValue.string))
    }

    private static let ownWindowsKey = "workbench.ownWindows"
    private func saveOwnWindows() {
        app.uiState[Self.ownWindowsKey] = .array((window?.editors.ownWindowIds ?? []).sorted().map(JSONValue.string))
    }
}
