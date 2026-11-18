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
}
