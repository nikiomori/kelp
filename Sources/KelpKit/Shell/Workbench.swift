import AppKit
import Core
import DesignKit
import Observation
import WorkbenchKit

/// What's on screen: the selected workspace and what has focus in it. The app has one (`app.workbench`), and whatever
/// acts on the window (opening tabs, showing workspaces, focusing agents) goes through it.
@MainActor
@Observable
package final class Workbench {
    @ObservationIgnored let app: AppModel
    /// The main window, once it's made (it hands itself over). Only Workbench*.swift reaches it, and the rest of the
    /// shell goes through the ways below (ArchitectureTests).
    @ObservationIgnored weak var window: MainWindowController?
    /// The main window's editor areas, one per recent workspace.
    var editors: EditorHost? { window?.editors }
    /// The main window itself, which sheets and menus hang off.
    var mainWindow: NSWindow? { window?.window }
    /// Focus Mode puts the side panels away, and also what a tab adds over its content (breadcrumbs).
    package internal(set) var inFocusMode = false

    // What an extension may ask of the window (it never gets the window itself).
    /// Brings the window of the workspace on screen to the front, as after a sheet or a settings change made elsewhere.
    package func bringToFront() { activeWindow?.makeKeyAndOrderFront(nil) }
    /// The content view of that window, where a menu with no button to open under shows (near its top).
    package var windowContent: NSView? { activeWindow?.contentView }
    /// The window the workspace on screen is in: a group's own window, or else the main window. Sheets hang off it.
    var activeWindow: NSWindow? { window?.editors.ownWindow(workspaceId) ?? window?.window }
    /// Shows an inspector panel by its id ("files", "ci"…).
    package func showPanel(_ id: String) { window?.showInspector(panel: id) }
    /// The panel's controller once the inspector has built it. It is nil before the panel is first shown.
    package func builtPanel(_ id: String) -> NSViewController? { window?.inspector.built(id) }
    /// The id of the inspector panel in its column beside the editors. It is nil while the inspector is hidden or only
    /// peeking.
    package var panelBeside: String? { inspectorDocked ? inspectorPanel : nil }
    /// True when the inspector is in its column beside the editors, not hidden or only peeking over them (the window
    /// sets this).
    var inspectorDocked = false
    /// The workspace the main window shows. `workspaceId` differs while a group's own window has the keys.
    var mainWorkspaceId: String?
    package var workspaceId: String? {
        didSet {
            app.uiState["workbench.lastWorkspace"] = workspaceId.map(JSONValue.string)
        }
    }
    /// Moves what is on screen now to the front of ⌃Tab's order: the server's page if one is shown over a workspace,
    /// or else the workspace.
    func noteShown() {
        guard let id = page ?? workspaceId else { return }
        app.uiState["workbench.recentWorkspaces"] = .array(
            ([id] + recentWorkspaces.filter { $0 != id }).prefix(50).map(JSONValue.string))
    }
    /// A page that is a place of its own, such as a server's page ("host:<name>"). It fills the editor area, with no
    /// tabs, until a workspace is shown again. `workspaceId` stays the workspace the page was shown over.
    package internal(set) var page: String?
    /// Workspaces and server pages by when they were last on screen, latest first, kept across launches. This is
    /// ⌃Tab's order.
    var recentWorkspaces: [String] { app.uiState.strings("workbench.recentWorkspaces") }
    init(app: AppModel) {
        self.app = app
        // What was looked at last follows the focus as it moves, and as another workspace comes on screen.
        track(owner: self, now: false) { [weak self] in
            [self?.workspaceId, self?.focusedTab]
        } changed: { [weak self] _ in
            self?.focusMoved()
        }
    }
    /// The URI of the tab with focus in the workspace on screen, from its layout. The sidebar marks the row of that
    /// tab's agent.
    package var focusedTab: String? { workspaceId.flatMap { layouts[$0].focusedGroup?.selectedTab?.uri } }
    /// Whether the workspace on screen puts its agents side by side as they open (the title bar's button, ⌃⌘T).
    var sideBySide: Bool { workspaceId.map { layouts[$0].manual != true } ?? true }
    /// The session last looked at in the workspace on screen, or else its newest chat. "Send to agent" and the diff's
    /// review go to it. It stays while a file or a page has the focus.
    package var lastSession: String?
    /// The file last looked at there (an extension's `{file}`). It stays while a terminal has the focus.
    var focusedFile: String?

    private func focusMoved() {
        let uri = focusedTab ?? ""
        switch TabURI.scheme(uri) {
        case "session": lastSession = TabURI.body(uri)
        case "file": focusedFile = TabURI.filePath(uri).path
        default: break
        }
        if lastSession.flatMap({ app.session($0)?.worktreeId }) != workspaceId {
            lastSession = app.sessions.last { $0.worktreeId == workspaceId && $0.status != .exited && $0.isChat }?.id
        }
        app.publishUIState()
    }
    var inspectorPanel: String = UserDefaults.standard.string(forKey: "inspectorPanel") ?? "" {   // "": the first one
        didSet { UserDefaults.standard.set(inspectorPanel, forKey: "inspectorPanel") }
    }
    /// Server and machine pages in windows of their own, by URI (`openInOwnWindow`).
    @ObservationIgnored var pageWindows: [String: OwnWindow] = [:]
    /// Every workspace's layout, loaded or not (`WorkspaceLayouts`).
    @ObservationIgnored lazy var layouts = WorkspaceLayouts(state: app.uiState)
    /// What ⇧⌘T brings back. It lives here, not in `EditorArea`, because an area not seen lately leaves memory.
    @ObservationIgnored var closedTabs = ClosedTabs()
    /// The history for Back / Forward (⌃⌘← / ⌃⌘→). It is observed, so the title bar's arrows follow it.
    var history = WorkspaceHistory()
    /// Columns × rows of the last terminal seen on screen, used to size the next terminal before it's shown. It is kept
    /// across launches, because the window usually opens at the same size.
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
