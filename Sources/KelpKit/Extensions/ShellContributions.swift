// What extensions hand the shell besides panels and commands: tabs, branch and CI hooks, sidebar parts, Contributions.
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
        browse: (@MainActor (_ tab: TabContent, _ action: String, _ args: JSONValue) async throws -> JSONValue)? = nil
    ) {
        self.schemes = schemes
        self.make = make
        self.placeholder = placeholder
        self.badge = badge
        self.releasable = releasable
        self.closeUnbuilt = closeUnbuilt
        self.menu = menu
        self.browse = browse
    }
    let schemes: [String]
    let make: @MainActor (String) -> TabContent?
    /// What its tab shows before it's built (a tab in the background since launch), from the URI alone: it must not do
    /// work. None: the URI and a puzzle piece.
    var placeholder: (@MainActor (_ uri: String) -> (title: String, icon: NSImage?, toolTip: String?))?
    /// Its marks while it isn't built, as its tab's `badge` would say them (a session's state and context ring).
    var badge: (@MainActor (_ uri: String) -> TabBadge?)?
    /// A tab of its hidden a while lets go of what it holds (a terminal's surface, ~25 MB) and is built again when shown
    /// (`EditorRelease`); meanwhile `placeholder` and `badge` stand in.
    let releasable: Bool
    /// Closing a tab of its URI that was never built (in the background since launch); false keeps it.
    var closeUnbuilt: (@MainActor (_ uri: String) async -> Bool)?
    /// Its items in the tab's context menu, added to `menu` above Close Tab: `workspace` is the editor area's, and
    /// `openBeside` opens a URI in a pane to the right.
    var menu:
        (
            @MainActor (
                _ menu: NSMenu, _ uri: String, _ workspace: String, _ openBeside: @escaping @MainActor (String) -> Void
            ) -> Void
        )?
    /// `kelp browser`'s `action` on a page tab it made (`UIBrowser`).
    var browse: (@MainActor (_ tab: TabContent, _ action: String, _ args: JSONValue) async throws -> JSONValue)?
}

/// Everything one extension adds. Built-ins fill it in Swift; folders from extension.json.
/// What the window bar's branch chip does, from the built-in that knows git (Git): what runs on a workspace's branch now
/// ("Pushing…") and the popover a click opens.
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

/// A folder's CI and pull request as marks, from the built-in that watches them (Git): beside the folder's sidebar row
/// and in the ⌃Tab switcher, on the window bar's chips, what they say, where a click goes, the PR in the folder's hover
/// card, and the branch chip's menu. Read under observation: they must not do work.
package struct FolderCI {
    /// Every folder's CI mark beside its row: the rows follow this, not each CI read.
    let rows: @MainActor () -> [String: CIRuns.State]
    let row: @MainActor (_ folder: String) -> CIRuns.State?
    /// On the branch chip: the mark, and whether it sits at the title's end (else in the branch glyph's place).
    let chip: @MainActor (_ folder: String) -> (state: CIRuns.State, atEnd: Bool)?
    /// "CI: Failed · Tests, Deploy", for tooltips and VoiceOver.
    let line: @MainActor (_ folder: String) -> String?
    let open: @MainActor (_ folder: String) -> Void
    /// The branch chip's menu for the workspace on screen: Create Pull Request while its branch has none, the CI items.
    let menu: @MainActor (_ menu: NSMenu, _ worktree: String?) -> Void
    /// The branch's pull request beside the folder: "#12" in its state's colour, what it says, and its page.
    let pr: @MainActor (_ folder: String) -> (title: NSAttributedString, tip: String, url: String)?
    /// The pull request in full, in the folder's hover card (nil: none).
    let card: @MainActor (_ folder: String) -> AnyView?
    /// The folder whose hover card is open, nil once it closes: its pull request is read meanwhile.
    let carded: @MainActor (_ folder: String?) -> Void
    package init(
        rows: @escaping @MainActor () -> [String: CIRuns.State],
        row: @escaping @MainActor (String) -> CIRuns.State?,
        chip: @escaping @MainActor (String) -> (state: CIRuns.State, atEnd: Bool)?,
        line: @escaping @MainActor (String) -> String?,
        open: @escaping @MainActor (String) -> Void,
        menu: @escaping @MainActor (NSMenu, String?) -> Void,
        pr: @escaping @MainActor (String) -> (title: NSAttributedString, tip: String, url: String)?,
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
        self.card = card
        self.carded = carded
    }
}

/// A mark on a session's row: an SF Symbol and what it says.
package struct SessionMark: Equatable {
    let symbol: String, tip: String
    package init(symbol: String, tip: String) {
        self.symbol = symbol
        self.tip = tip
    }
}

/// A block of a built-in's own in the sidebar, under the projects (Machines): its view, made when the sidebar is.
/// `foot`: at the very bottom, under every other block (the plan limits).
package struct SidebarSection {
    let id: String
    let foot: Bool
    let make: @MainActor () -> NSView
    package init(id: String, foot: Bool = false, make: @escaping @MainActor () -> NSView) {
        self.id = id
        self.foot = foot
        self.make = make
    }
}

/// The sidebar's server cards, from the built-in that knows SSH servers (Servers): the header over the projects on one
/// host and what a remote project's hover card adds (their menus are its `rowMenu`). None, and a remote project is a row
/// like any other.
package struct ServerCards {
    /// The header's row, brought up to date by the sidebar as its rows and its card's look change.
    let header: @MainActor (_ host: String, _ row: ServerRow) -> SidebarRow
    /// In a remote project's hover card, under its title; `close` puts the card away.
    let section: @MainActor (_ host: String, _ close: @escaping () -> Void) -> AnyView
    /// The hosts the sidebar lists, each time it builds its rows.
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

/// What a server's header asks the sidebar: whether its projects are folded away, to fold or open them, and the striped
/// plate under its icon when that is how its card is marked (Settings › Appearance › Servers; nil: none).
package struct ServerRow {
    package let folded: @MainActor () -> Bool
    package let fold: @MainActor () -> Void
    package let plate: @MainActor () -> NSColor?
}

/// A row a built-in makes for the sidebar (a server's header): `update` shows what it stands for now.
@MainActor
package protocol SidebarRow: NSView {
    func update()
}

package struct Contributions {
    /// What a built-in hands over, once (a folder extension's are read from its manifest).
    package init(
        panels: [PanelSpec] = [], editors: [EditorSpec] = [], commands: [CommandSpec] = [],
        settings: [SettingsSection] = [], tabs: [TabProvider] = [], sidebarSections: [SidebarSection] = [],
        sessionMarks: [@MainActor (Session) -> SessionMark?] = [], sessionHidden: [@MainActor () -> Set<String>] = [],
        rowMenu: [@MainActor (_ row: SidebarItem.Kind, _ menu: NSMenu) -> Void] = [], branch: BranchActions? = nil,
        ci: FolderCI? = nil,
        pushed: [@MainActor (any Pushed) -> Void] = [], plans: PlanWords? = nil, servers: ServerCards? = nil,
        launched: [@MainActor () -> Void] = [], dockMenu: [@MainActor (NSMenu) -> Void] = [],
        dockUsage: (@MainActor () -> DockFace?)? = nil, runs: ProjectRuns? = nil, languages: [LanguageSpec] = [],
        skills: [SkillSpec] = []
    ) {
        self.panels = panels
        self.editors = editors
        self.commands = commands
        self.settings = settings
        self.tabs = tabs
        self.sidebarSections = sidebarSections
        self.sessionMarks = sessionMarks
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
    }
    package var panels: [PanelSpec] = []
    var editors: [EditorSpec] = []
    var commands: [CommandSpec] = []
    var settings: [SettingsSection] = []
    var themes: [Theme] = []
    var iconThemes: [IconThemeSpec] = []
    var agents: [AgentManifest] = []
    var tabs: [TabProvider] = []
    /// Blocks of its own in the sidebar, under the projects (Machines), made when the sidebar is and only while it's on.
    var sidebarSections: [SidebarSection] = []
    /// A mark on an agent's sidebar row for where it runs something of the built-in's (a machine): the first that has one
    /// shows, when the row has no goal or command of its own to show. Read under observation: it must not do work.
    var sessionMarks: [@MainActor (Session) -> SessionMark?] = []
    /// Sessions it keeps running with no tab and no sidebar row (Run's runs put away in the Run menu). Read under
    /// observation: it must not do work.
    var sessionHidden: [@MainActor () -> Set<String>] = []
    /// Items at the top of a sidebar row's menu (a project's, a server's header…), each ending with its separator: a
    /// merged PR's "Switch to main and Pull", a server's own.
    var rowMenu: [@MainActor (_ row: SidebarItem.Kind, _ menu: NSMenu) -> Void] = []
    /// The branch chip's actions: one built-in's (the first that has them); none, and the chip only shows the branch.
    var branch: BranchActions?
    /// The CI and PR marks on folders' rows and the window bar: one built-in's (the first that has them); none, and no
    /// CI or pull request shows.
    package var ci: FolderCI?
    /// Each reading the daemon pushes, as it lands (not only the latest: a limit's pace takes every one).
    var pushed: [@MainActor (any Pushed) -> Void] = []
    /// What the plan limits say beside each agent where agents are chosen, under the first-task field and of a session one
    /// stopped: one built-in's; none, and nothing of plans shows.
    var plans: PlanWords?
    /// The sidebar's server cards: one built-in's (the first that has them); none, and remote projects are plain rows.
    var servers: ServerCards?
    /// Run once when Kelp has started, its window up: what a built-in keeps going by itself (the agent strip).
    var launched: [@MainActor () -> Void] = []
    /// Items of its own in the Dock icon's menu, under New Chat.
    var dockMenu: [@MainActor (NSMenu) -> Void] = []
    /// The Dock icon's face when it shows Plan Usage (nil: nothing to show): one built-in's; none, and the plain icon.
    var dockUsage: (@MainActor () -> DockFace?)?
    /// What runs in a workspace: its chip, the Run menu, its tabs and pages: one built-in's (the first that has it).
    var runs: ProjectRuns?
    /// In load order: `LanguageSpec.find` lets a later one replace an earlier one with the same id.
    package var languages: [LanguageSpec] = []
    /// What it teaches agents (`AgentSkills`).
    var skills: [SkillSpec] = []

    /// Another extension's, after this one's (the registry merges them in load order): a list takes its items after
    /// these, a single hook stays the first one's. A new field gets its line here, beside the fields.
    mutating func add(_ c: Contributions) {
        panels += c.panels
        editors += c.editors
        commands += c.commands
        settings += c.settings
        themes += c.themes
        iconThemes += c.iconThemes
        agents += c.agents
        tabs += c.tabs
        languages += c.languages
        sidebarSections += c.sidebarSections
        sessionMarks += c.sessionMarks
        sessionHidden += c.sessionHidden
        rowMenu += c.rowMenu
        branch = branch ?? c.branch
        ci = ci ?? c.ci
        pushed += c.pushed
        plans = plans ?? c.plans
        servers = servers ?? c.servers
        launched += c.launched
        dockMenu += c.dockMenu
        dockUsage = dockUsage ?? c.dockUsage
        runs = runs ?? c.runs
        skills += c.skills
    }
}
