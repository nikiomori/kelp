import AppKit
import Core
import DesignKit
import WorkbenchKit

/// `kelp browser`: an agent's command, done in a page tab of its workspace. That workspace needn't be on screen, only
/// loaded (shown lately): its tabs live on while another one is shown.
extension UIRequests {
    func browse(_ event: UIBrowserEvent) {
        Task {
            let reply: UIBrowserReply
            do { reply = UIBrowserReply(request: event.request, result: try await run(event)) } catch {
                reply = UIBrowserReply(request: event.request, error: AppModel.message(error))
            }
            _ = await app.quiet(reply)   // the daemon went: nobody is waiting for it
        }
    }

    private func run(_ event: UIBrowserEvent) async throws -> JSONValue {
        guard let wid = event.worktreeId ?? app.workbench.workspaceId else {
            throw RPCError.invalidParams("No workspace to open a page in.")
        }
        guard let area = app.workbench.editors?.area(wid) else {
            throw RPCError.invalidParams("This workspace isn't open in Kelp's window: show it once, then try again.")
        }
        guard let action = BrowserAction(rawValue: event.action) else {
            throw RPCError.invalidParams("kelp browser knows no \(event.action)")
        }
        let args = event.args ?? .object([:])
        if action == .open, let page = try await area.pageForOpen(shared: args["shared"]?.bool == true, args: args) {
            return try await area.browse(page, .info, args)
        }
        guard let page = area.browsedPage() else {
            throw RPCError.invalidParams("No page of yours open in this workspace: kelp browser open <url> first.")
        }
        return try await area.browse(page, action, args)
    }
}

extension EditorArea {
    /// A new page tab for `open`, beside the agent's pane; nil when there's one to navigate already: the page it drove, or
    /// an agent's own, of the kind asked (`shared`: the user's cookies, which only a plain page has). A shared one acts as
    /// the user, so the user says so first.
    func pageForOpen(shared: Bool, args: JSONValue) async throws -> TabRef? {
        let url = args["url"]?.string ?? ""
        // A shared page is the one site the user allowed: another site is asked for again, in a tab of its own.
        if let page = ownPage(), shared == (TabURI.scheme(page.uri) != TabURI.agentScheme),
            !shared || url.isEmpty
                || PageOrigin.of(URL(string: url)) == PageOrigin.of(URL(string: TabURI.pageURL(page.uri)))
        {
            return nil
        }
        guard !url.isEmpty else { return nil }
        if shared, await !Self.allowShared(url) {
            throw RPCError.invalidParams(
                "The user didn't let you use their logged-in browser: kelp browser open without --shared.")
        }
        let uri = shared ? url : TabURI.agentPage(url)
        if app.workbench.editors?.current === self {
            showAside(uri, split: .right)
        } else {
            open(uri, split: .right, focus: false)
        }
        guard let page = layout.tab(uri: uri) ?? layout.pageTab(for: uri) else { return nil }
        browsing = page.id
        return page
    }

    /// The page `kelp browser` drives here: one it opened. The user's own page tabs carry their logins, so an agent never
    /// takes one of those by itself.
    func browsedPage() -> TabRef? {
        let page = ownPage()
        browsing = page?.id
        return page
    }

    /// Asked before `open --shared`: the page gets the user's cookies, and what the agent does there it does as them.
    private static func allowShared(_ url: String) async -> Bool {
        await confirm(
            String(localized: "Let an agent use your logged-in browser?"),
            detail: String(localized: "It opens \(url) with your cookies and can act as you on that site."),
            action: String(localized: "Allow"), cancel: String(localized: "Don't Allow"))
    }

    /// The action, by the tab's provider, on the tab, built if it wasn't yet.
    func browse(_ page: TabRef, _ action: BrowserAction, _ args: JSONValue) async throws -> JSONValue {
        guard let tab = content(page), let browse = app.extensions.tabProvider(for: page.uri)?.browse else {
            throw RPCError.invalidParams("That tab shows no page.")
        }
        return try await browse(tab, action.rawValue, args)
    }

    /// The page it drove last (one it opened: `browsing` is set only by `open` and by this), else an agent's own.
    private func ownPage() -> TabRef? {
        layout.allTabs.first { $0.id == browsing && TabURI.isPage($0.uri) }
            ?? layout.allTabs.first { TabURI.scheme($0.uri) == TabURI.agentScheme }
    }
}
