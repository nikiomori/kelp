import AppKit
import Core

/// Groups in windows of their own (`WorkspaceWindow`): the keys say which workspace is on screen — the main window's or
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
    }

    private static let ownWindowsKey = "workbench.ownWindows"
    private func saveOwnWindows() {
        app.uiState[Self.ownWindowsKey] = .array((window?.editors.ownWindowIds ?? []).sorted().map(JSONValue.string))
    }
}
