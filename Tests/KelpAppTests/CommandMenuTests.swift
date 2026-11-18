import AppKit
import Core
import Foundation
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

    /// The commands on the chat, the group and the project in front are offered only while there is one: none with no
    /// screen, the project's on its own screen, and all of them on a chat in a group.
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
        func offered() -> [String] {
            (onChat + onGroup + onProject).filter { app.extensions.command($0)?.enabled?() == true }
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
            #expect(offered() == onProject)
            app.workbench.show(workspace: "group")
            #expect(offered() == onChat + onGroup + onProject)
        }
    }
}
