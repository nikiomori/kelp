import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WorkbenchKit

@testable import KelpApp
@testable import KelpKit

/// A tab with nothing in it, which stands in for a chat's terminal.
@MainActor private final class EmptyTab: TabContent {
    let uri: String
    let view = NSView()
    var title: String { uri }
    var icon: NSImage? { nil }
    init(_ uri: String) { self.uri = uri }
    func focus() {}
    func close() async -> Bool { true }
}

/// A panel that is one list of three rows, which notes the row each action was about.
@MainActor private final class ListPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    var acted: [Int] = []
    override func loadView() {
        table.addTableColumn(NSTableColumn())
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(act)
        let scroll = NSScrollView()
        scroll.documentView = table
        view = scroll
    }
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "row")
    }
    @objc func act() { acted.append(table.actedRow) }
}

/// Where a command shows: the menu bar and ⇧⌘P, and for the File menu's commands on what is in front, when.
extension OneAtATime {
    /// Every command the registry has is an item of the menu bar, and every one the menu bar offers now is a row of
    /// ⇧⌘P. A command gets both by being registered, with nothing to add by hand. Show Panel is the one the menu bar
    /// lists another way: once for each panel.
    @Test func everyCommandIsInTheMenuBarAndThePalette() throws {
        _ = testHome
        _ = NSApplication.shared
        let before = NSApp.mainMenu
        defer { NSApp.mainMenu = before }
        let delegate = AppDelegate(builtins: Builtins.all), app = delegate.app
        app.extensions.reload()
        delegate.buildMenu()
        var items: [String: NSMenuItem] = [:]
        for (item, _) in try #require(NSApp.mainMenu).leaves() {
            if let id = item.identifier?.rawValue { items[id] = item }
        }
        let commands = app.extensions.all.commands
        #expect(!commands.isEmpty, "the built-ins' commands weren't registered")
        #expect(commands.map(\.id).filter { items[$0] == nil } == ["workbench.showPanel"])
        let palette = QuickOpen(app: app)
        palette.commandsOnly = true
        palette.collect()
        let rows = Set(palette.all.filter { $0.kind == "Command" }.map(\.title))
        // Read after the palette, which asks the same question: an item that says what choosing it does (Show Sidebar)
        // has its title by then.
        let offered = commands.compactMap { items[$0.id] }.filter { !$0.isHidden && delegate.validateMenuItem($0) }
        #expect(!offered.isEmpty && offered.map(\.title).filter { !rows.contains($0) } == [])
    }

    /// The commands on what is in front are offered only while it is there: none with no screen, the folder's and the
    /// project's on a project's own screen, the chat's and the group's too on a chat in a group, the tabs' while the
    /// focused tab has others beside it or to its right, and the branch's while the folder is on a branch.
    @Test func commandsOnWhatIsInFrontAreOfferedWhileItIsThere() {
        _ = testHome
        _ = NSApplication.shared
        // Listed first, so a chat's tab is this one and no terminal is made for it.
        let chats = Builtin("test.chats", "Chats", "", icon: "doc") { _ in
            Contributions(tabs: [TabProvider(schemes: ["session"]) { EmptyTab($0) }])
        }
        let app = AppModel(builtins: [chats] + Builtins.all)
        app.extensions.reload()
        let onChat = ["agents.rename", "agents.markUnread", "agents.restart", "agents.fork", "agents.copyContext"]
        let onGroup = ["workspace.renameGroup", "workspace.archiveGroup"]
        let onProject = ["workspace.renameProject", "workspace.removeProject"]
        let onTabs = ["editor.closeOtherTabs", "editor.closeTabsToRight"]
        let onFolder = ["workspace.copyPath"], onBranch = ["git.copyBranchName"]
        func offered() -> [String] {
            (onTabs + onFolder + onBranch + onChat + onGroup + onProject).filter {
                app.extensions.command($0)?.enabled?() == true
            }
        }
        let folder = NSTemporaryDirectory()   // a folder that is there, so the project isn't one to locate
        withExtendedLifetime(MainWindowController(app: app)) {   // the workbench holds its window weakly
            app.repos = [Repo(id: "r", name: "Atlas", path: folder)]
            app.worktrees = [
                Worktree(id: "own", repoId: "r", branch: "main", path: folder, createdAt: .distantPast),
                Worktree(id: "group", repoId: "r", branch: "main", path: folder, note: "Group")
            ]
            app.sessions = [Session(id: "s", worktreeId: "group", cwd: folder, command: "claude", agent: "claude")]
            app.workbench.layouts["group"].add(TabURI.session("s"))
            #expect(offered() == [])
            app.workbench.show(workspace: "own")
            #expect(offered() == onFolder + onProject)
            app.workbench.show(workspace: "group")
            #expect(offered() == onFolder + onChat + onGroup + onProject)
            // A second tab, behind the chat's, is beside it and to its right. With that last tab in front, none is to
            // the right, and the tab is no chat.
            let last = app.workbench.layouts["group"].add(TabURI.session("other"), select: false)
            #expect(offered() == onTabs + onFolder + onChat + onGroup + onProject)
            app.workbench.layouts["group"].select(last.id)
            #expect(offered() == ["editor.closeOtherTabs"] + onFolder + onGroup + onProject)
            // The branch is what the daemon pushed for the group's folder. A detached HEAD has none.
            for (branch, offers) in [("main", true), (nil, false)] as [(String?, Bool)] {
                let info = BranchInfo(current: branch, head: "abc1234", local: [], remote: [], merging: false)
                app.land(GitEvent(worktree: app.gitKey("group"), branches: info))
                #expect(offered().contains("git.copyBranchName") == offers)
            }
        }
    }

    /// A search of the commands that finds nothing says so in the list's place, as the line and symbol modes say
    /// theirs. One that finds something has rows and no such line.
    @Test func thePaletteSaysWhenNothingMatches() async throws {
        _ = testHome
        _ = NSApplication.shared
        let before = NSApp.mainMenu
        defer { NSApp.mainMenu = before }
        let delegate = AppDelegate(builtins: Builtins.all), app = delegate.app
        app.extensions.reload()
        delegate.buildMenu()   // the palette's commands are the menu bar's
        let palette = QuickOpen(app: app)
        palette.build()
        palette.commandsOnly = true
        palette.collect()
        let command = try #require(palette.all.first { $0.kind == "Command" })
        func headings() -> [String] {
            palette.rows.compactMap { if case .heading(let text) = $0 { text } else { nil } }
        }
        palette.field.stringValue = "zzqqxxjj"
        palette.filter()
        #expect(try await waitFor(5) { palette.rows.count == 1 && headings() == ["No matches"] })
        palette.field.stringValue = command.title
        palette.filter()
        #expect(try await waitFor(5) { palette.rows.contains(where: \.isItem) && !headings().contains("No matches") })
    }

    /// ⌥⌘1–9 are the icons of the inspector's row, in its order: a panel dragged to the front is ⌥⌘1, and one hidden
    /// from the row has no number. A panel's key gives its list the keys, where Return does what a click on the
    /// selected row does; the same command without the menu's word leaves the keys where they were. VoiceOver hears
    /// the number on a panel's icon with the panel's name.
    @Test func aPanelsKeyIsItsIconsPlaceAndGivesItsListTheKeys() async throws {
        _ = testHome
        _ = NSApplication.shared
        let before = NSApp.mainMenu
        defer { NSApp.mainMenu = before }
        let panel = ListPanel()
        let lists = Builtin("test.lists", "Lists", "", icon: "doc") { _ in
            Contributions(panels: [
                PanelSpec(
                    id: "test.list", title: "Test List", icon: "list.bullet", extensionId: "test.lists",
                    badge: { PanelBadge("3") }
                ) { panel }
            ])
        }
        let delegate = AppDelegate(builtins: Builtins.all + [lists]), app = delegate.app
        app.extensions.reload()
        func numbered() throws -> [String] {
            delegate.buildMenu()
            return try #require(NSApp.mainMenu).leaves().map(\.0)
                .filter { $0.keyEquivalentModifierMask == [.command, .option] && (Int($0.keyEquivalent) ?? 0) > 0 }
                .sorted { $0.keyEquivalent < $1.keyEquivalent }.map { $0.title.trimmingCharacters(in: .whitespaces) }
        }
        let registered = app.extensions.all.panels
        #expect(try numbered() == registered.prefix(9).map { loc($0.title) })
        let first = try #require(registered.first)
        app.settings.set(SettingKeys.panelOrder, ["test.list"])
        app.settings.set(SettingKeys.hiddenPanels, [first.id])
        defer {
            app.settings.set(SettingKeys.panelOrder, nil)
            app.settings.set(SettingKeys.hiddenPanels, nil)
        }
        let now = try numbered()
        #expect(now.first == "Test List" && !now.contains(loc(first.title)))

        let folder = NSTemporaryDirectory()
        let controller = MainWindowController(app: app)
        app.repos = [Repo(id: "r", name: "Atlas", path: folder)]
        app.worktrees = [Worktree(id: "own", repoId: "r", branch: "main", path: folder, createdAt: .distantPast)]
        app.workbench.show(workspace: "own")
        controller.right.item.isCollapsed = false   // open at once: the slide that opens it takes its time
        await mainActorTurns()   // the inspector hears of the project a turn later
        try withExtendedLifetime(controller) {
            let window = try #require(controller.window)
            app.extensions.run("workbench.showPanel", ["panel": .string("test.list")])
            #expect(window.firstResponder !== panel.table)
            app.extensions.run("workbench.showPanel", ["panel": .string("test.list"), "keys": .bool(true)])
            #expect(window.firstResponder === panel.table)
            panel.table.selectRowIndexes([1], byExtendingSelection: false)
            let key = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            panel.table.keyDown(with: key)
            #expect(panel.acted == [1])
            // The number on the panel's icon is said with its name.
            #expect(controller.inspector.buttons.map { $0.accessibilityLabel() }.contains("Test List, 3"))
        }
    }
}
