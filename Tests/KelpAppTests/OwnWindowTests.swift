import AppKit
import Core
import Foundation
import TestSupport
import Testing

@testable import KelpApp
@testable import KelpKit

/// Windows of their own (`OwnWindow`): a group's, and a server's or a machine's page's. The keys, what's seen and what's
/// read follow the window they're in, not the main one alone.

/// A page that notes itself when it's made, and when it's asked to close.
@MainActor private final class Page: TabContent {
    /// What a test reads back: every page made, latest last, and the ones asked to close, by URI.
    @MainActor final class Log {
        var made: [Page] = []
        var asked: [String] = []
    }
    let uri: String
    let view = NSView()
    var title: String { uri }
    var icon: NSImage? { nil }
    private let log: Log
    init(_ uri: String, log: Log) {
        self.uri = uri
        self.log = log
        log.made.append(self)
    }
    func focus() {}
    func close() async -> Bool {
        log.asked.append(uri)
        return true
    }
}

/// A main window over an app of its own: two groups, each with a tab, `a` on screen. "page:" URIs make a `Page`.
/// A test's window never gets the keys and is never seen: what AppKit would say is said by hand (`keys`, and the
/// closures `sightChanged` and `editorInFront` take).
@MainActor private final class Windows {
    let app: AppModel, main: MainWindowController
    let pages = Page.Log()
    var wb: Workbench { app.workbench }
    static let server = "page:server"

    init() {
        _ = testHome
        let log = pages
        let made = Builtin("test.pages", "Pages", "", icon: "doc") { _ in
            Contributions(tabs: [TabProvider(schemes: ["page"]) { Page($0, log: log) }])
        }
        app = AppModel(builtins: Builtins.all + [made])
        app.extensions.reload()
        main = MainWindowController(app: app)
        app.repos = [Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-own-atlas")]
        app.worktrees = ["a", "b"].map {
            Worktree(id: $0, repoId: "r1", branch: "main", path: "/tmp/kelp-own-atlas", note: $0)
        }
        for id in ["a", "b"] { app.workbench.layouts[id].add("page:tab-" + id) }
        app.workbench.show(workspace: "a")
    }

    func own(_ id: String) -> NSWindow? { main.editors.ownWindow(id) }
    /// Kelp is away when, of all its windows, only `window` is seen (nil: none).
    func away(seeing window: NSWindow?) -> Bool {
        wb.sightChanged { $0 === window }
        return app.away
    }
    /// The workspace whose editor area has the keyboard: what ⌘T and the pane and tab commands act on. Nil: none.
    var keyboard: String? { wb.starter == nil ? nil : wb.editor?.workspaceId }
    /// AppKit's word that a page's own window got the keys, or gave them up.
    func keys(_ uri: String, _ has: Bool) {
        let window = wb.pageWindows[uri]
        if has {
            window?.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        } else {
            window?.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        }
    }

    /// The windows it opened close, and their saved frames go.
    func done() {
        for id in main.editors.ownWindowIds { main.editors.leaveOwnWindow(id) }
        for (uri, window) in wb.pageWindows {
            window.close()
            NSWindow.removeFrame(usingName: "page." + uri)
        }
        for id in ["a", "b"] { NSWindow.removeFrame(usingName: "workspace." + id) }
    }
}

extension OneAtATime {
    /// A group into a window of its own and back: its tabs and the screen you're on stay; the main window shows what
    /// was there before meanwhile.
    @Test func aGroupGoesToItsOwnWindowAndBackWithItsTabs() throws {
        let w = Windows()
        defer { w.done() }
        w.wb.show(workspace: "b")
        let tabs = w.wb.layouts["b"].allTabs
        w.wb.moveToOwnWindow("b")
        let window = try #require(w.own("b"))
        #expect(w.wb.workspaceId == "b" && w.wb.mainWorkspaceId == "a")
        #expect(w.keyboard == "b" && w.wb.activeWindow === window)
        #expect(w.main.editors.area("b")?.view.window === window)
        #expect(w.wb.layouts["b"].allTabs == tabs)
        w.wb.returnToMain("b")   // its close button
        #expect(w.own("b") == nil && w.wb.workspaceId == "b" && w.wb.mainWorkspaceId == "b")
        #expect(w.main.editors.area("b")?.view.window === w.main.window)
        #expect(w.wb.layouts["b"].allTabs == tabs)
    }

    /// What was in windows of its own is there again at the next launch: groups and pages.
    @Test func ownWindowsComeBackAtLaunch() {
        let first = Windows(), next = Windows()
        defer {
            first.done()
            next.done()
        }
        first.wb.moveToOwnWindow("b")
        first.wb.openInOwnWindow(Windows.server)
        for (key, value) in first.app.uiState.all(prefix: "workbench.") where key.hasSuffix("Windows") {
            next.app.uiState[key] = value
        }
        #expect(!next.wb.inOwnWindow("b") && next.wb.pageWindows.isEmpty)
        next.wb.reopenOwnWindows()
        #expect(next.wb.inOwnWindow("b") && next.wb.mainWorkspaceId == "a")
        #expect(next.wb.pageWindows.keys.sorted() == [Windows.server])
    }

    /// ⌘W in a server's or a machine's own window closes that window, as its close button does; what acts on an editor
    /// area (⌘T, the pane and tab commands) finds none there, rather than the main window's.
    @Test func closeTabInAPagesOwnWindowClosesThatWindow() async throws {
        let w = Windows()
        defer { w.done() }
        let area = try #require(w.main.editors.area("a"))
        #expect(area.focusedContent != nil && w.keyboard == "a")
        w.wb.openInOwnWindow(Windows.server)
        w.keys(Windows.server, true)
        #expect(w.keyboard == nil)
        #expect(w.wb.starterForNewTab != nil)   // what adds a tab from the page still reaches the workspace
        w.app.extensions.command("editor.closeTab")?.run([:])
        #expect(try await waitFor(3) { w.wb.pageWindows.isEmpty })
        await mainActorTurns()
        #expect(w.pages.asked == [Windows.server])   // the page itself was asked, as by the close button; no tab was
        #expect(area.layout.allTabs.map(\.uri) == ["page:tab-a"])   // the main window's tab stays
    }

    /// The keys back in the main window: its editor area has the keyboard again.
    @Test func theEditorAreaHasTheKeyboardAgainAfterAPagesWindow() {
        let w = Windows()
        defer { w.done() }
        w.wb.openInOwnWindow(Windows.server)
        w.keys(Windows.server, true)
        #expect(w.keyboard == nil)
        w.keys(Windows.server, false)
        #expect(w.keyboard == "a")
    }

    /// Kelp is away only while none of its windows that show a workspace or a page is seen: a group's or a page's own
    /// window in view keeps what it shows read, with the main window minimized or covered.
    @Test func kelpIsAwayOnlyWhenNoneOfItsWindowsIsSeen() throws {
        let w = Windows()
        defer { w.done() }
        w.wb.moveToOwnWindow("b")
        w.wb.openInOwnWindow(Windows.server)
        let group = try #require(w.own("b")), page = try #require(w.wb.pageWindows[Windows.server]?.window)
        #expect(w.away(seeing: nil))
        #expect(!w.away(seeing: group))
        #expect(w.away(seeing: nil) && !w.away(seeing: page))
        #expect(w.away(seeing: nil) && !w.away(seeing: w.main.window))
    }

    /// A glance counts for the window that shows the agent: a group's own while it has the keys, the main one after;
    /// a page's own window in front reads no agent.
    @Test func aGlanceCountsForTheWindowThatShowsTheAgent() throws {
        let w = Windows()
        defer { w.done() }
        w.wb.moveToOwnWindow("b")
        let group = try #require(w.own("b"))
        #expect(w.wb.editorInFront { $0 === group }?.workspaceId == "b")
        #expect(w.wb.editorInFront { $0 === w.main.window }?.workspaceId == nil)
        w.wb.mainWindowBecameKey()
        #expect(w.wb.editorInFront { $0 === w.main.window }?.workspaceId == "a")
        w.wb.openInOwnWindow(Windows.server)
        w.keys(Windows.server, true)
        #expect(w.wb.editorInFront { _ in true }?.workspaceId == nil)
    }

    /// A group removed from elsewhere (the CLI, an agent) while its own window has the keys: the window goes, and the
    /// screen you're on is the main window's, not the one that's gone.
    @Test func aGroupRemovedWithTheKeysLeavesTheMainWindowsOnScreen() async throws {
        let w = Windows()
        defer { w.done() }
        w.wb.moveToOwnWindow("b")
        #expect(w.wb.workspaceId == "b")
        w.app.worktrees.removeAll { $0.id == "b" }
        #expect(try await waitFor(3) { w.own("b") == nil })
        #expect(w.wb.workspaceId == "a" && w.keyboard == "a")
    }

    /// The workspace under a server's page moved to a window of its own: the page left the main window with it, so
    /// its row opens it again.
    @Test func aPageOverAGroupMovedToItsOwnWindowOpensAgain() {
        let w = Windows()
        defer { w.done() }
        w.wb.show(page: Windows.server)
        #expect(w.wb.page == Windows.server)
        w.wb.moveToOwnWindow("a")
        #expect(w.wb.page == nil)
        w.wb.show(page: Windows.server)   // its row
        #expect(w.wb.page == Windows.server && w.pages.made.last?.view.window === w.main.window)
    }
}
