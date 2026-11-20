import AppKit
import Core
import WorkbenchKit

/// What runs in a workspace, provided by the built-in that runs a project's commands (Run): the window bar's run chip
/// and the page it serves, the Run menu's project commands, how a run's tab looks and its menu, and what the "+" menu
/// and the empty workspace offer to run. Without that built-in, none of it shows: no chip and no run choices (a
/// template's and a new workspace's commands run as plain sessions, `KelpFile`). What the tabs follow (`look`, `port`,
/// `tabsFollow`, `choices`) is read under observation, so it must not do work. The runs put away in the Run menu are
/// reported through `Contributions.sessionHidden`.
package struct ProjectRuns {
    /// The items to the right of the search in the window bar, before the cup.
    let bar: @MainActor () -> [any WindowBarItem]
    /// The Run menu's delegate, which puts the project's other commands between the menu's separators as it opens.
    let menu: any NSMenuDelegate
    /// How a run's tab looks among the terminals: the symbol of its purpose in grey, with no glow (a purpose's colour
    /// lives in the Run menu while it runs). nil for any other session.
    let look: @MainActor (Session) -> (icon: NSImage?, glow: NSColor?)?
    /// The port after a tab's name.
    let port: @MainActor (Session) -> Int?
    /// What the tabs' looks and ports depend on; the tab strips are drawn again when it changes.
    let tabsFollow: @MainActor () -> [String]
    /// A live session's tab menu, before Close Tab.
    let tabMenu: @MainActor (NSMenu, Session) -> Void
    /// The Run rows of the "+" menu and the empty workspace for a workspace; none while the workspace has nothing to
    /// run.
    let choices: @MainActor (_ workspace: String) -> [NewTabChoices.Action]
    /// Opens a page that the hover card lists, in a pane to the right, without taking the keys. For a page that isn't
    /// a web page, its address is copied instead.
    let open: @MainActor (ServedPage, _ workspace: String) -> Void
    /// Starts a .kelp.yaml command the way Run starts one: an earlier copy is ended, the new one is kept as the
    /// workspace's run, and it is put away in the Run menu if its last copy was. Its trust has been asked already
    /// (`KelpFile`), and opening its tab is left to the caller.
    let run: @MainActor (_ workspace: String, _ name: String) async -> Session?
    package init(
        bar: @escaping @MainActor () -> [any WindowBarItem],
        menu: any NSMenuDelegate,
        look: @escaping @MainActor (Session) -> (icon: NSImage?, glow: NSColor?)?,
        port: @escaping @MainActor (Session) -> Int?,
        tabsFollow: @escaping @MainActor () -> [String],
        tabMenu: @escaping @MainActor (NSMenu, Session) -> Void,
        choices: @escaping @MainActor (String) -> [NewTabChoices.Action],
        open: @escaping @MainActor (ServedPage, String) -> Void,
        run: @escaping @MainActor (String, String) async -> Session?
    ) {
        self.bar = bar
        self.menu = menu
        self.look = look
        self.port = port
        self.tabsFollow = tabsFollow
        self.tabMenu = tabMenu
        self.choices = choices
        self.open = open
        self.run = run
    }
}

/// A part a built-in puts in the window bar (Run's chip, the page it serves). It is told the bar's width each time the
/// bar lays out, so it can shorten itself without its own size feeding back on the choice.
@MainActor
package protocol WindowBarItem: NSView {
    func fit(barWidth: CGFloat)
}
