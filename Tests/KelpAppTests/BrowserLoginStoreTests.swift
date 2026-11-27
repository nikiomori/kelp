import AppKit
import Core
import Foundation
import TestSupport
import Testing
import WebKit
import WorkbenchKit

@testable import BuiltinBrowser
@testable import KelpKit

/// An agent's page keeps nothing once its tab closes, a chat's own included: a store per chat would make each chat a new
/// device to a site, which asks again for codes and captchas. The user's own page keeps their cookies.
@MainActor @Test func anAgentsPageKeepsNothingAndTheUsersKeepsTheirs() {
    let app = AppModel(), chat = UUID().uuidString
    app.sessions = [Session(id: chat, worktreeId: "w", cwd: "/tmp", command: "claude", agent: "claude")]
    let chats = BrowserTab(uri: TabURI.agentPage("about:blank", session: chat), app: app)
    let unowned = BrowserTab(uri: TabURI.agentPage("about:blank"), app: app)
    let users = BrowserTab(uri: "about:blank", app: app)
    #expect(chats.agent && !chats.web.configuration.websiteDataStore.isPersistent)
    #expect(!unowned.web.configuration.websiteDataStore.isPersistent)
    #expect(!users.agent && users.web.configuration.websiteDataStore.isPersistent)
}

extension OneAtATime {
    /// A login kelpd marked for a command from outside Kelp's chats (no session: a script, an agent in another terminal
    /// app) has no row to ask on: on a site not in the list the app asks with a sheet, and Don't Allow refuses it.
    @Test func aLoginForACommandFromOutsideKelpsChatsIsAskedFor() async throws {
        _ = testHome
        _ = NSApplication.shared
        let app = AppModel(builtins: [Builtins.browser])
        app.extensions.reload()
        let main = MainWindowController(app: app)
        defer { withExtendedLifetime(main) {} }
        app.repos = [Repo(id: "p", name: "Pages", path: "/tmp")]
        app.worktrees = [Worktree(id: "w", repoId: "p", branch: "main", path: "/tmp")]
        let bench = app.workbench, requests = BrowserRequests(app: app)
        bench.show(workspace: "w")
        let window = try #require(main.window)
        window.orderFrontRegardless()   // a window never on screen gets no sheet
        defer { window.orderOut(nil) }
        let open = Task {
            try await requests.run(
                UIBrowserEvent(
                    UIBrowser(
                        action: .open, args: .object(["url": "about:blank", "yourLogin": "example.com"]),
                        worktreeId: "w"),
                    request: "outside"))
        }
        #expect(try await waitFor(10) { window.attachedSheet != nil })
        if let asked = window.attachedSheet { window.endSheet(asked, returnCode: .alertSecondButtonReturn) }
        await #expect(throws: RPCError.self) { try await open.value }
        let pages = (bench.loadedTabs("w") ?? []).filter { TabURI.isPage($0.uri) }
        #expect(pages.isEmpty, "\(pages.map(\.uri))")
    }
}
