// What extensions give the shell besides panels and commands: tabs, branch and CI hooks, sidebar parts, and the
// `Contributions` struct that holds them all.
import Agents
import AppKit
import Core
import SwiftUI
import WorkbenchKit

/// Opens tabs for URIs of a scheme ("session", "file", "https"…).
package struct TabProvider {
    package init(
        schemes: [String], make: @escaping @MainActor (String) -> TabContent?,
        placeholder: (@MainActor (_ uri: String) -> (title: String, icon: NSImage?, toolTip: String?))? = nil,
        badge: (@MainActor (_ uri: String) -> TabBadge?)? = nil, releasable: Bool = false,
        closeUnbuilt: (@MainActor (_ uri: String) async -> Bool)? = nil,
        menu: (
            @MainActor (
                _ menu: NSMenu, _ uri: String, _ workspace: String, _ openBeside: @escaping @MainActor (String) -> Void
            ) -> Void
        )? = nil,
        driven: (@MainActor (_ workspace: String) -> [String: (session: String, glow: NSColor?)])? = nil
    ) {
        self.schemes = schemes
        self.make = make
        self.placeholder = placeholder
        self.badge = badge
        self.releasable = releasable
        self.closeUnbuilt = closeUnbuilt
        self.menu = menu
        self.driven = driven
    }
    let schemes: [String]
    let make: @MainActor (String) -> TabContent?
    /// What the provider's tab shows before the tab is built (a tab left in the background since launch). It works from
    /// the URI alone and must not do work. Without it, the tab shows the URI and a puzzle piece.
    var placeholder: (@MainActor (_ uri: String) -> (title: String, icon: NSImage?, toolTip: String?))?
    /// The marks a tab shows while it isn't built, as the tab's own `badge` would show them (a session's state and
    /// context ring).
    var badge: (@MainActor (_ uri: String) -> TabBadge?)?
    /// Whether this provider's tabs, once hidden for a while, let go of what they hold (a terminal's surface, ~25 MB)
    /// and are built again when shown (`EditorRelease`). Meanwhile `placeholder` and `badge` stand in.
    let releasable: Bool
    /// Closes a tab of this provider that was never built (in the background since launch). Returning false keeps the
    /// tab.
    var closeUnbuilt: (@MainActor (_ uri: String) async -> Bool)?
    /// Items added to the tab's context menu, above Close Tab: `workspace` is the editor area's workspace, and
    /// `openBeside` opens a URI in a pane to the right.
    var menu:
        (
            @MainActor (
                _ menu: NSMenu, _ uri: String, _ workspace: String, _ openBeside: @escaping @MainActor (String) -> Void
            ) -> Void
        )?
    /// The built-in's tabs in `workspace` that an agent drives (a page that `kelp browser` acts in), keyed by tab id.
    /// Each entry names the agent's session and the glow while it acts. Such a tab wears the agent's logo and card.
    /// This is read under observation, so it must not do work.
    var driven: (@MainActor (_ workspace: String) -> [String: (session: String, glow: NSColor?)])?
}

/// What the branch chip on the window bar does, supplied by the built-in that knows git (Git): what is running on a
/// workspace's branch now ("Pushing…"), and the popover a click opens.
package struct BranchActions {
    let running: @MainActor (_ worktree: String) -> String?
    let popover: @MainActor (_ worktree: String, _ popover: NSPopover) -> NSViewController
    package init(
        running: @escaping @MainActor (String) -> String?,
        popover: @escaping @MainActor (String, NSPopover) -> NSViewController
    ) {
        self.running = running
        self.popover = popover
    }
}

/// A folder's CI and pull request shown as marks, supplied by the built-in that watches them (Git). The marks show
/// beside the folder's sidebar row, in the ⌃Tab switcher and on the chips of the window bar. This struct says what the
/// marks say and where a click goes, gives the PR for the folder's hover card, and fills the branch chip's menu. It is
/// read under observation, so it must not do work.
package struct FolderCI {
    /// The CI mark of every folder, shown beside its row. The rows follow this map rather than each CI read.
    let rows: @MainActor () -> [String: CIRuns.State]
    let row: @MainActor (_ folder: String) -> CIRuns.State?
    /// The mark on the branch chip, and whether it sits at the end of the title (otherwise in place of the branch
    /// glyph).
    let chip: @MainActor (_ folder: String) -> (state: CIRuns.State, atEnd: Bool)?
    /// "CI: Failed · Tests, Deploy", for tooltips and VoiceOver.
    let line: @MainActor (_ folder: String) -> String?
    let open: @MainActor (_ folder: String) -> Void
    /// Fills the branch chip's menu for the workspace on screen: Create Pull Request while its branch has none, and the
    /// CI items.
    let menu: @MainActor (_ menu: NSMenu, _ worktree: String?) -> Void
    /// The pull request of the folder's branch, shown beside the folder: "#12" in the colour of its state, its tooltip,
    /// the tab a click opens, and its page on the forge, which a ⌘-click opens in the browser.
    let pr: @MainActor (_ folder: String) -> (title: NSAttributedString, tip: String, uri: String, page: URL?)?
    /// Makes a CI mark in the built-in's look (12 pt) for a row, the branch chip or a tile. It returns the view and a
    /// function that shows a state in it. `spelled` means the row is under the pointer, and the function returns how
    /// much wider than 12 pt the mark then is.
    let mark: @MainActor () -> (view: NSView, show: @MainActor (CIRuns.State?, _ spelled: Bool) -> CGFloat)
    /// The pull request in full, for the folder's hover card (nil when there is none).
    let card: @MainActor (_ folder: String) -> AnyView?
    /// Tells the built-in which folder's hover card is open (nil once it closes), so that folder's pull request is read
    /// while the card is open.
    let carded: @MainActor (_ folder: String?) -> Void
    package init(
        rows: @escaping @MainActor () -> [String: CIRuns.State],
        row: @escaping @MainActor (String) -> CIRuns.State?,
        chip: @escaping @MainActor (String) -> (state: CIRuns.State, atEnd: Bool)?,
        line: @escaping @MainActor (String) -> String?,
        open: @escaping @MainActor (String) -> Void,
        menu: @escaping @MainActor (NSMenu, String?) -> Void,
        pr: @escaping @MainActor (String) -> (title: NSAttributedString, tip: String, uri: String, page: URL?)?,
        mark: @escaping @MainActor () -> (view: NSView, show: @MainActor (CIRuns.State?, Bool) -> CGFloat),
        card: @escaping @MainActor (String) -> AnyView?,
        carded: @escaping @MainActor (String?) -> Void
    ) {
        self.rows = rows
        self.row = row
        self.chip = chip
        self.line = line
        self.open = open
        self.menu = menu
        self.pr = pr
        self.mark = mark
        self.card = card
        self.carded = carded
    }
}

/// A mark a built-in puts on a row: the machine an agent runs a command in, the page it drives, or the CI of its
/// workspace on its tile in the Dock strip. It is read under observation, so it must not do work. Each reader shows
/// only the places it has.
package struct RowMark: Equatable {
    /// Where a mark shows. `chip`: on an agent's sidebar row, in place of the chip, when the row has no goal or command
    /// of its own to show. `button`: on an agent's sidebar row, as a button of its own beside the dots, in `tint` and
    /// glowing in `glow`, where a click runs `open`. `tile`: in the corner of the Dock strip's tile for an agent in the
    /// workspace, with a menu that offers `open` under `tip`.
    package enum Place: Sendable { case chip, button, tile }
    package let place: Place
    /// An SF Symbol name. When it is nil, `view` makes a mark the built-in draws itself (Git's CI mark) when the mark
    /// is shown.
    let symbol: String?
    package let view: (@MainActor () -> NSView)?
    let tint: NSColor?, glow: NSColor?
    package let tip: String
    /// The subagents whose dots the mark lights on the agent's row (those acting on a page), and the colour it uses.
    let lights: Set<String>, lightColor: NSColor?
    package let open: (@MainActor () -> Void)?
    /// A key for what a `view` shows (CI's state), so a reader can tell when it changed.
    package let key: String
    package init(
        _ place: Place, symbol: String? = nil, view: (@MainActor () -> NSView)? = nil, tint: NSColor? = nil,
        glow: NSColor? = nil, tip: String, lights: Set<String> = [], lightColor: NSColor? = nil, key: String = "",
        open: (@MainActor () -> Void)? = nil
    ) {
        self.place = place
        self.symbol = symbol
        self.view = view
        self.tint = tint
        self.glow = glow
        self.tip = tip
        self.lights = lights
        self.lightColor = lightColor
        self.key = key
        self.open = open
    }
    /// Compares what shows, leaving the closures aside.
    package static func == (a: RowMark, b: RowMark) -> Bool {
        (a.place, a.symbol, a.tint, a.glow, a.tip) == (b.place, b.symbol, b.tint, b.glow, b.tip)
            && (a.lights, a.lightColor, a.key) == (b.lights, b.lightColor, b.key)
    }
}

/// A block a built-in adds to the sidebar under the projects (Machines). Its view is made when the sidebar is made.
/// `foot` puts the block at the very bottom, under every other block (the plan limits). A block with a `title` and a
/// `shown` setting has a check mark under View › Sidebar Blocks that shows or hides it.
package struct SidebarSection {
    let id: String
    let foot: Bool
    let title: String?
    let shown: Setting<Bool>?
    let make: @MainActor () -> NSView
    package init(
        id: String, foot: Bool = false, title: String? = nil, shown: Setting<Bool>? = nil,
        make: @escaping @MainActor () -> NSView
    ) {
        self.id = id
        self.foot = foot
        self.title = title
        self.shown = shown
        self.make = make
    }
}

/// The sidebar's server cards, supplied by the built-in that knows SSH servers (Servers): the header over the projects
/// on one host, and what a remote project's hover card adds. Their menus come from the built-in's `rowMenu`. Without
/// server cards, a remote project is a row like any other.
package struct ServerCards {
    /// Makes the header's row. The sidebar brings it up to date as the server's rows and the card's look change.
    let header: @MainActor (_ host: String, _ row: ServerRow) -> SidebarRow
    /// The part a remote project's hover card shows under its title; `close` puts the card away.
    let section: @MainActor (_ host: String, _ close: @escaping () -> Void) -> AnyView
    /// Tells the built-in which hosts the sidebar lists, each time the sidebar builds its rows.
    let listed: @MainActor (_ hosts: Set<String>) -> Void
    package init(
        header: @escaping @MainActor (String, ServerRow) -> SidebarRow,
        section: @escaping @MainActor (String, @escaping () -> Void) -> AnyView,
        listed: @escaping @MainActor (Set<String>) -> Void
    ) {
        self.header = header
        self.section = section
        self.listed = listed
    }
}

/// What a server's header asks of the sidebar: whether the server's projects are folded away, a way to fold or open
/// them, and the striped plate under its icon when that is how its card is marked (Settings › Appearance › Servers; nil
/// when it isn't).
package struct ServerRow {
    package let folded: @MainActor () -> Bool
    package let fold: @MainActor () -> Void
    package let plate: @MainActor () -> NSColor?
}

/// A row a built-in makes for the sidebar (a server's header). `update` makes the row show the current state of what it
/// stands for.
@MainActor
package protocol SidebarRow: NSView {
    func update()
}

/// Everything one extension adds. Built-ins fill it in Swift; folder extensions fill it from extension.json.
package struct Contributions {
    /// What a built-in hands over, once. A folder extension's contributions are read from its manifest instead.
    package init(
        panels: [PanelSpec] = [], editors: [EditorSpec] = [], commands: [CommandSpec] = [],
        settings: [SettingsSection] = [], tabs: [TabProvider] = [], sidebarSections: [SidebarSection] = [],
        rowMarks: [@MainActor (SidebarItem.Kind) -> [RowMark]] = [], sessionHidden: [@MainActor () -> Set<String>] = [],
        rowMenu: [@MainActor (_ row: SidebarItem.Kind, _ menu: NSMenu) -> Void] = [], branch: BranchActions? = nil,
        ci: FolderCI? = nil,
        pushed: [@MainActor (any Pushed) -> Void] = [], plans: PlanWords? = nil, servers: ServerCards? = nil,
        launched: [@MainActor () -> Void] = [], dockMenu: [@MainActor (NSMenu) -> Void] = [],
        dockUsage: (@MainActor () -> DockFace?)? = nil, runs: ProjectRuns? = nil, languages: [LanguageSpec] = [],
        skills: [SkillSpec] = [],
        agentCards: [@MainActor (_ session: Session, _ close: @escaping @MainActor () -> Void) -> AnyView?] = [],
        subagentSteps: [@MainActor (_ session: String, _ subagent: String, _ command: String) -> String?] = [],
        events: [@MainActor (any RPCEvent) -> Bool] = [],
        quickPrefixes: [String: @MainActor (_ typed: String) async -> [QuickItem]] = [:]
    ) {
        self.panels = panels
        self.editors = editors
        self.commands = commands
        self.settings = settings
        self.tabs = tabs
        self.sidebarSections = sidebarSections
        self.rowMarks = rowMarks
        self.sessionHidden = sessionHidden
        self.rowMenu = rowMenu
        self.branch = branch
        self.ci = ci
        self.pushed = pushed
        self.plans = plans
        self.servers = servers
        self.launched = launched
        self.dockMenu = dockMenu
        self.dockUsage = dockUsage
        self.runs = runs
        self.languages = languages
        self.skills = skills
        self.agentCards = agentCards
        self.subagentSteps = subagentSteps
        self.events = events
        self.quickPrefixes = quickPrefixes
    }
    package var panels: [PanelSpec] = []
    var editors: [EditorSpec] = []
    var commands: [CommandSpec] = []
    var settings: [SettingsSection] = []
    var themes: [Theme] = []
    var iconThemes: [IconThemeSpec] = []
    var agents: [AgentManifest] = []
    var tabs: [TabProvider] = []
    /// The extension's own blocks in the sidebar under the projects (Machines), made when the sidebar is made and only
    /// while the extension is on.
    var sidebarSections: [SidebarSection] = []
    /// Marks on rows (`RowMark`), such as an agent's row and its tile in the Dock strip. They are read under
    /// observation, so they must not do work.
    var rowMarks: [@MainActor (SidebarItem.Kind) -> [RowMark]] = []
    /// Sessions the extension keeps running with no tab and no sidebar row (runs that Run put away in the Run menu).
    /// This is read under observation, so it must not do work.
    var sessionHidden: [@MainActor () -> Set<String>] = []
    /// Items added at the top of a sidebar row's menu (a project's, a server's header…), each ending with its
    /// separator: for example a merged PR's "Switch to main and Pull", or a server's own items.
    var rowMenu: [@MainActor (_ row: SidebarItem.Kind, _ menu: NSMenu) -> Void] = []
    /// The branch chip's actions, from one built-in (the first that has them). Without them, the chip only shows the
    /// branch.
    var branch: BranchActions?
    /// The CI and PR marks on folders' rows and the window bar, from one built-in (the first that has them). Without
    /// them, no CI or pull request shows.
    package var ci: FolderCI?
    /// Hears each reading the daemon pushes as it lands, not only the latest, because a limit's pace needs every
    /// reading.
    var pushed: [@MainActor (any Pushed) -> Void] = []
    /// What the plan limits say beside each agent where agents are chosen, under the first-task field, and about a
    /// session that a limit stopped. It comes from one built-in; without it, nothing about plans shows.
    var plans: PlanWords?
    /// The sidebar's server cards, from one built-in (the first that has them). Without them, remote projects are plain
    /// rows.
    var servers: ServerCards?
    /// Runs once when Kelp has started and its window is up, to start what a built-in keeps going by itself (the agent
    /// strip).
    var launched: [@MainActor () -> Void] = []
    /// The extension's own items in the Dock icon's menu, under New Chat.
    var dockMenu: [@MainActor (NSMenu) -> Void] = []
    /// The Dock icon's face when it shows Plan Usage (nil when there is nothing to show). One built-in provides it;
    /// with none, the Dock shows the plain icon.
    var dockUsage: (@MainActor () -> DockFace?)?
    /// What runs in a workspace (its chip, the Run menu, its tabs and pages), from one built-in (the first that has
    /// it).
    var runs: ProjectRuns?
    /// Languages in load order, so `LanguageSpec.find` lets a later language replace an earlier one with the same id.
    package var languages: [LanguageSpec] = []
    /// The skills the extension teaches agents (`AgentSkills`).
    var skills: [SkillSpec] = []
    /// The extension's part of an agent's hover card (such as the page the agent drives), shown under what the card
    /// says about the agent. `close` puts the card away. The part is made while the card is up.
    var agentCards: [@MainActor (_ session: Session, _ close: @escaping @MainActor () -> Void) -> AnyView?] = []
    /// What a subagent's last command did, in the built-in's own words, for the agent's card (for a `kelp browser`
    /// command, the page's last step). Nil shows the command as it ran.
    var subagentSteps: [@MainActor (_ session: String, _ subagent: String, _ command: String) -> String?] = []
    /// Hears daemon events the shell keeps no record of (a page a session printed, a port another program holds, an
    /// agent's `kelp browser` command) as they come. A handler returns true when it took the event, and the later
    /// handlers aren't asked. When no handler takes an agent's browser command, the agent is told the Browser is off.
    var events: [@MainActor (any RPCEvent) -> Bool] = []
    /// Lists for ⌘P, keyed by a character the built-in claims, for what is typed after that character ("#" gives the
    /// pull requests of Issues). When two built-ins claim the same character, the first wins.
    var quickPrefixes: [String: @MainActor (_ typed: String) async -> [QuickItem]] = [:]

    /// Merges another extension's contributions after this one's (the registry merges them in load order): a list gets
    /// the other's items after these, and a single hook keeps the first extension's. A new field needs its own line
    /// here too.
    mutating func add(_ contributions: Contributions) {
        panels += contributions.panels
        editors += contributions.editors
        commands += contributions.commands
        settings += contributions.settings
        themes += contributions.themes
        iconThemes += contributions.iconThemes
        agents += contributions.agents
        tabs += contributions.tabs
        languages += contributions.languages
        sidebarSections += contributions.sidebarSections
        rowMarks += contributions.rowMarks
        sessionHidden += contributions.sessionHidden
        rowMenu += contributions.rowMenu
        branch = branch ?? contributions.branch
        ci = ci ?? contributions.ci
        pushed += contributions.pushed
        plans = plans ?? contributions.plans
        servers = servers ?? contributions.servers
        launched += contributions.launched
        dockMenu += contributions.dockMenu
        dockUsage = dockUsage ?? contributions.dockUsage
        runs = runs ?? contributions.runs
        skills += contributions.skills
        agentCards += contributions.agentCards
        subagentSteps += contributions.subagentSteps
        events += contributions.events
        quickPrefixes.merge(contributions.quickPrefixes) { first, _ in first }
    }
}
