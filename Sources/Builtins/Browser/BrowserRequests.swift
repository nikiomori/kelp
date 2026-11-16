import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// `kelp browser`: an agent's command, done in a page tab of its workspace. That workspace needn't be on screen, only
/// loaded (shown lately): its tabs live on while another one is shown.
@MainActor
struct BrowserRequests {
    let app: AppModel

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

    /// A new page tab for `open`, beside the agent's pane; nil when there's one to navigate already: the page it drove, or
    /// an agent's own, of the kind asked (`shared`: the user's cookies, which only a plain page has). A shared one acts as
    /// the user, so the user says so first.
    private func pageForOpen(_ wid: String, shared: Bool, args: JSONValue) async throws -> TabRef? {
        let url = args["url"]?.string ?? ""
        // A shared page is the one site the user allowed: another site is asked for again, in a tab of its own. A local
        // page (`preview:`) is a tab's start, not an address to go to, so it gets a tab of its own too.
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

    /// The page `kelp browser` drives here: one it opened. The user's own page tabs carry their logins, so an agent never
    /// takes one of those by itself.
    private func browsedPage(_ wid: String) -> TabRef? {
        let page = ownPage(wid)
        AgentPages.of(app).browsed[wid] = page?.id
        return page
    }

    /// Asked before `open --shared`: the page gets the user's cookies, and what the agent does there it does as them.
    private static func allowShared(_ url: String) async -> Bool {
        await confirm(
            String(localized: "Let an agent use your logged-in browser?"),
            detail: String(localized: "It opens \(url) with your cookies and can act as you on that site."),
            action: String(localized: "Allow"), cancel: String(localized: "Don't Allow"))
    }

    /// The action on the page, its tab built if it wasn't yet.
    private func browse(_ page: TabRef, in wid: String, _ action: BrowserAction, _ args: JSONValue) async throws
        -> JSONValue
    {
        guard let tab = app.workbench.content(page, in: wid) as? BrowserTab else {
            throw RPCError.invalidParams("That tab shows no page.")
        }
        // Where the page is, for the marks it shows outside its tab (`AgentPages`).
        var args = args
        if case .object(var fields) = args {
            fields["tab"] = .string(page.id)
            fields["workspace"] = .string(wid)
            args = .object(fields)
        }
        return try await tab.browse(action, args)
    }

    /// The page it drove last (one it opened: `browsed` is set only by `open` and by this), else an agent's own.
    private func ownPage(_ wid: String) -> TabRef? {
        Self.ownPage(app.workbench.loadedTabs(wid) ?? [], last: AgentPages.of(app).browsed[wid])
    }

    static func ownPage(_ tabs: [TabRef], last: String?) -> TabRef? {
        tabs.first { $0.id == last && TabURI.isPage($0.uri) }
            ?? tabs.first { TabURI.scheme($0.uri) == TabURI.agentScheme }
    }
}
