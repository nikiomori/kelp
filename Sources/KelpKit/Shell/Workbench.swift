import AppKit
import Core
import Observation
import WorkbenchKit

/// What's on screen: the selected workspace and what has focus in it. The app's (`app.workbench`): what acts on the
/// window (opening tabs, showing workspaces, focusing agents) is reached through it.
@MainActor
@Observable
package final class Workbench {
    @ObservationIgnored let app: AppModel
    /// The main window, once it's made (it hands itself over).
    @ObservationIgnored weak var window: MainWindowController?
    /// Focus Mode: the side panels away, and what a tab adds over its content (breadcrumbs) too.
    package internal(set) var inFocusMode = false

    // What an extension may ask of the window (it never gets the window itself).
    /// Brings the main window to the front, as after a sheet or a settings change made elsewhere.
    package func bringToFront() { window?.window?.makeKeyAndOrderFront(nil) }
    /// The main window's content: where a menu with no button to open under shows (near its top).
    package var windowContent: NSView? { window?.window?.contentView }
    /// Shows an inspector panel by its id ("files", "ci"…).
    package func showPanel(_ id: String) { window?.showInspector(panel: id) }
    /// The panel that shows `role`, whichever built-in's it is; none on, nothing happens.
    func showPanel(_ role: PanelRole) {
        if let panel = app.extensions.all.panels.first(where: { $0.role == role }) { showPanel(panel.id) }
    }
    /// The panel's controller once the inspector has built it; nil before it's first shown.
    package func builtPanel(_ id: String) -> NSViewController? { window?.inspector.built(id) }
    /// The inspector panel in its column beside the editors, by id; nil while the inspector is hidden or only peeking.
    /// Observable as far as the panel picked; the column opening or closing resizes the editors, which tabs see as a layout.
    package var panelBeside: String? { window?.inspectorDocked == true ? inspectorPanel : nil }
    package var workspaceId: String? {
        didSet {
            app.uiState["workbench.lastWorkspace"] = workspaceId.map(JSONValue.string)
            if workspaceId != oldValue { app.syncContextWatches() }   // the rings on the tabs now on screen
        }
    }
    /// What's on screen now goes to the front of ⌃Tab's order: the server's page over a workspace, else the workspace.
    func noteShown() {
        guard let id = page ?? workspaceId else { return }
        app.uiState["workbench.recentWorkspaces"] = .array(
            ([id] + recentWorkspaces.filter { $0 != id }).prefix(50).map(JSONValue.string))
    }
    /// A page that is a place of its own, a server's ("host:<name>"): it fills the editor area, with no tabs, until a
    /// workspace is shown again. `workspaceId` stays the one it was shown over.
    package internal(set) var page: String?
    /// Workspaces and servers' pages by when they were last on screen, latest first, kept across launches: ⌃Tab's
    /// order.
    var recentWorkspaces: [String] { app.uiState.strings("workbench.recentWorkspaces") }
    init(app: AppModel) { self.app = app }
    package var focusedSession: String?
    /// The tab with focus in the workspace on screen (its URI): the sidebar marks its agent's row.
    package internal(set) var focusedTab: String?
    var focusedFile: String?
    /// The workspace on screen puts its agents side by side as they open (the title bar's button, ⌃⌘T).
    var sideBySide = true
    var inspectorPanel: String = UserDefaults.standard.string(forKey: "inspectorPanel") ?? "" {   // none yet: the first
        didSet { UserDefaults.standard.set(inspectorPanel, forKey: "inspectorPanel") }
    }
    /// What ⇧⌘T brings back. Here, not in `EditorArea`: an area not seen lately leaves memory.
    @ObservationIgnored var closedTabs = ClosedTabs()
    /// For Back / Forward (⌃⌘← / ⌃⌘→). Observed: the title bar's arrows follow it.
    var history = WorkspaceHistory()
    /// Columns × rows of the last terminal seen on screen: sizes the next one before it's shown. Kept across launches:
    /// the window usually opens at the same size.
    @ObservationIgnored package var terminalGrid: (cols: Int, rows: Int)? = {
        let grid = UserDefaults.standard.array(forKey: "terminal.lastGrid") as? [Int] ?? []
        return grid.count == 2 ? (grid[0], grid[1]) : nil
    }()
    {
        didSet {
            if let grid = terminalGrid, grid != oldValue ?? (0, 0) {
                UserDefaults.standard.set([grid.cols, grid.rows], forKey: "terminal.lastGrid")
            }
        }
    }
}
