import AppKit
import Core
import WorkbenchKit

/// What runs in a workspace, from the built-in that runs a project's commands (Run): the window bar's run chip and the
/// page it serves, the Run menu's project commands, how a run's tab looks and its menu, what the "+" menu and the empty
/// workspace offer to run, the pages a run prints and a new workspace's setup. None, and nothing of it shows: no chip,
/// no run choices, every session a row and a tab. What the sidebar and the tabs follow (`hidden`, `look`, `port`,
/// `tabsFollow`, `choices`) is read under observation: it must not do work.
package struct ProjectRuns {
    /// Right of the search in the window bar, before the cup.
    let bar: @MainActor () -> [any WindowBarItem]
    /// The Run menu's delegate: the project's other commands go between its separators as it opens.
    let menu: any NSMenuDelegate
    /// Runs put away in the Run menu: they keep running with no tab and no sidebar row.
    let hidden: @MainActor () -> Set<String>
    /// A run's tab among the terminals: its purpose's symbol in colour and a glow of that colour; nil for any other.
    let look: @MainActor (Session) -> (icon: NSImage?, glow: NSColor?)?
    /// The port after a tab's name.
    let port: @MainActor (Session) -> Int?
    /// What the tabs' looks and ports follow: the tab strips are drawn again when it changes.
    let tabsFollow: @MainActor () -> [String]
    /// A live session's tab menu, before Close Tab.
    let tabMenu: @MainActor (NSMenu, Session) -> Void
    /// The "+" menu's and the empty workspace's Run rows for a workspace; none while it offers nothing to run.
    let choices: @MainActor (_ workspace: String) -> [NewTabChoices.Action]
    /// A page the hover card lists, opened beside you (one that isn't a web page has its address copied).
    let open: @MainActor (ServedPage, _ workspace: String) -> Void
    /// A page a session printed: true when it's a run's, which waits on the chip for a click.
    let served: @MainActor (DevServerEvent) -> Bool
    /// A run that couldn't start: says who holds its port.
    let portBusy: @MainActor (PortBusyEvent) -> Void
    /// A new workspace whose .kelp.yaml setup waits for the file's trust; the pull request it holds, if any.
    let setup: @MainActor (_ workspace: String, _ pullRequest: Int?) async -> Void
    package init(
        bar: @escaping @MainActor () -> [any WindowBarItem],
        menu: any NSMenuDelegate,
        hidden: @escaping @MainActor () -> Set<String>,
        look: @escaping @MainActor (Session) -> (icon: NSImage?, glow: NSColor?)?,
        port: @escaping @MainActor (Session) -> Int?,
        tabsFollow: @escaping @MainActor () -> [String],
        tabMenu: @escaping @MainActor (NSMenu, Session) -> Void,
        choices: @escaping @MainActor (String) -> [NewTabChoices.Action],
        open: @escaping @MainActor (ServedPage, String) -> Void,
        served: @escaping @MainActor (DevServerEvent) -> Bool,
        portBusy: @escaping @MainActor (PortBusyEvent) -> Void,
        setup: @escaping @MainActor (String, Int?) async -> Void
    ) {
        self.bar = bar
        self.menu = menu
        self.hidden = hidden
        self.look = look
        self.port = port
        self.tabsFollow = tabsFollow
        self.tabMenu = tabMenu
        self.choices = choices
        self.open = open
        self.served = served
        self.portBusy = portBusy
        self.setup = setup
    }
}

/// A part a built-in puts in the window bar (Run's chip, the page it serves): told the bar's width each time the bar
/// lays out, so it can shorten itself without its own size feeding back on the choice.
@MainActor
package protocol WindowBarItem: NSView {
    func fit(barWidth: CGFloat)
}
