import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Runs an agent's `kelp browser` command in a page tab of the agent's workspace. That workspace needn't be on screen,
/// only loaded (shown lately), because its tabs live on while another workspace is shown.
@MainActor
struct BrowserRequests {
    let app: AppModel

    func browse(_ event: UIBrowserEvent) {
        Task {
            let reply: UIBrowserReply
            do { reply = UIBrowserReply(request: event.request, result: try await run(event)) } catch {
                reply = UIBrowserReply(request: event.request, error: AppModel.message(error))
            }
            _ = await app.quiet(reply)   // if the daemon went away, nobody is waiting for the reply
        }
    }

    private func run(_ event: UIBrowserEvent) async throws -> JSONValue {
        guard let wid = event.worktreeId ?? app.workbench.workspaceId else {
            throw RPCError.invalidParams("No workspace to open a page in.")
        }
        guard app.workbench.loadedTabs(wid) != nil else {
            throw RPCError.invalidParams("This workspace isn't open in Kelp's window: show it once, then try again.")
        }
        let action = event.action
        let args = event.args ?? .object([:])
        if action == .open, let page = try await pageForOpen(wid, shared: args["shared"]?.bool == true, args: args) {
            return try await browse(page, in: wid, .info, args)
        }
        guard let page = browsedPage(wid) else {
            throw RPCError.invalidParams("No page of yours open in this workspace: kelp browser open <url> first.")
        }
        return try await browse(page, in: wid, action, args)
    }

    /// Opens a new page tab for `open`, beside the agent's pane. It returns nil when there is already a page to
    /// navigate, which is the page the agent drove, or the agent's own page of the kind asked for. `shared` asks for a
    /// page with the user's cookies, which only a plain page has. A shared page acts as the user, so the user has to
    /// say yes first.
    private func pageForOpen(_ wid: String, shared: Bool, args: JSONValue) async throws -> TabRef? {
        let url = args["url"]?.string ?? ""
        // A shared page stays on the one site the user allowed, so another site is asked for again, in a tab of its
        // own. A local page (`preview:`) is where a tab starts, not an address to go to, so it gets a tab of its own
        // too.
        if let page = ownPage(wid), shared == (TabURI.scheme(page.uri) != TabURI.agentScheme),
            TabURI.scheme(url) != "preview",
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
        guard let page = app.workbench.openBeside(shared ? url : TabURI.agentPage(url), in: wid) else { return nil }
        AgentPages.of(app).browsed[wid] = page.id
        return page
    }

    /// Returns the page `kelp browser` drives in this workspace, which is always one it opened. The user's own page
    /// tabs carry their logins, so an agent never takes one of those by itself.
    private func browsedPage(_ wid: String) -> TabRef? {
        let page = ownPage(wid)
        AgentPages.of(app).browsed[wid] = page?.id
        return page
    }

    /// Asks the user before `open --shared`, because the page gets the user's cookies and the agent acts as the user
    /// there.
    private static func allowShared(_ url: String) async -> Bool {
        await confirm(
            String(localized: "Let an agent use your logged-in browser?"),
            detail: String(localized: "It opens \(url) with your cookies and can act as you on that site."),
            action: String(localized: "Allow"), cancel: String(localized: "Don’t Allow"))
    }

    /// Runs the action on the page, building the page's tab first if it wasn't built yet.
    private func browse(_ page: TabRef, in wid: String, _ action: BrowserAction, _ args: JSONValue) async throws
        -> JSONValue
    {
        guard let tab = app.workbench.content(page, in: wid) as? BrowserTab else {
            throw RPCError.invalidParams("That tab shows no page.")
        }
        // Add where the page is, for the marks it shows outside its tab (`AgentPages`).
        var args = args
        if case .object(var fields) = args {
            fields["tab"] = .string(page.id)
            fields["workspace"] = .string(wid)
            args = .object(fields)
        }
        return try await tab.browse(action, args)
    }

    /// Returns the page the agent drove last, or else an agent's own page. The page driven last is always one the agent
    /// opened, because only `open` and `browsedPage` set `browsed`.
    private func ownPage(_ wid: String) -> TabRef? {
        Self.ownPage(app.workbench.loadedTabs(wid) ?? [], last: AgentPages.of(app).browsed[wid])
    }

    static func ownPage(_ tabs: [TabRef], last: String?) -> TabRef? {
        tabs.first { $0.id == last && TabURI.isPage($0.uri) }
            ?? tabs.first { TabURI.scheme($0.uri) == TabURI.agentScheme }
    }
}
