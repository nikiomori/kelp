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

    func run(_ event: UIBrowserEvent) async throws -> JSONValue {
        guard let wid = event.worktreeId ?? app.workbench.workspaceId else {
            throw RPCError.invalidParams("No workspace to open a page in.")
        }
        guard let tabs = app.workbench.loadedTabs(wid) else {
            throw RPCError.invalidParams("This workspace isn't open in Kelp's window: show it once, then try again.")
        }
        let action = event.action
        let args = event.args ?? .object([:])
        let session = args["session"]?.string, subagent = args["subagent"]?.string
        let remote = args["remote"].map { $0 != .null } ?? false
        let owner = remote ? AgentPages.remotePrefix + (session ?? "user") : session ?? "user"
        let scope = AgentPages.Scope(workspace: wid, owner: owner, subagent: subagent)
        let pages = AgentPages.of(app), last = pages.browsed[scope]
        let page = Self.ownPage(tabs, session: owner, last: last)
        guard action == .open else {
            guard let page else { throw Self.noPage }
            if let site = last?.sharedSite, session != nil, !allows(site) {
                pages.browsed[scope] = nil
                throw RPCError.refused("The user took back their login on \(site).")
            }
            return try await browse(page, in: wid, action, args)
        }

        guard let url = args["url"]?.string, !url.isEmpty else { throw RPCError.invalidParams("open needs url") }
        // kelpd alone says an open gets the user's login (`BrowserRelay.login`); it refused `--shared` without it.
        if let site = args["yourLogin"]?.string { return try await openWithLogin(site, url, scope, tabs, args) }
        guard args["shared"]?.bool != true else {
            throw RPCError.refused("The user didn't let you use their login there.")
        }

        let privatePage = last?.sharedSite == nil ? page : Self.ownPage(tabs, session: owner, last: nil)
        // Previews use their starting file. Native subagents use subpages of a private tab, which starts empty
        // if the parent hasn't opened a page yet. Host pages attach their network before loading an address.
        if let privatePage, subagent != nil || TabURI.scheme(url) != "preview" {
            pages.browsed[scope] = AgentPages.Visit(tab: privatePage.id, sharedSite: nil)
            return try await browse(privatePage, in: wid, .open, args)
        }
        let start = subagent != nil ? "" : remote ? "about:blank" : url
        guard let page = app.workbench.openBeside(TabURI.agentPage(start, session: owner), in: wid) else {
            throw Self.noPage
        }
        pages.browsed[scope] = AgentPages.Visit(tab: page.id, sharedSite: nil)
        return try await browse(page, in: wid, remote || subagent != nil ? .open : .info, args)
    }

    /// Opens `url` with the user's login from Kelp's browser, in a page tab of the chat's own beside it: the one it
    /// used for `site` before, while that is still on the site. A subagent uses its chat's.
    private func openWithLogin(
        _ site: String, _ url: String, _ scope: AgentPages.Scope, _ tabs: [TabRef], _ args: JSONValue
    ) async throws -> JSONValue {
        let pages = AgentPages.of(app), wid = scope.workspace
        let chat = AgentPages.Scope(workspace: wid, owner: scope.owner, subagent: nil)
        if let last = pages.browsed[chat], last.sharedSite == site,
            let page = Self.ownPage(tabs, session: scope.owner, last: last)
        {
            pages.browsed[scope] = last
            return try await browse(page, in: wid, .open, args, login: site)
        }
        guard let page = app.workbench.openBeside(url, in: wid, reuse: false) else { throw Self.noPage }
        pages.browsed[chat] = AgentPages.Visit(tab: page.id, sharedSite: site)
        pages.browsed[scope] = pages.browsed[chat]
        return try await browse(page, in: wid, .info, args, login: site)
    }

    /// Whether agents may still use the user's login on `site` (Settings › Browser, a page's Stop).
    private func allows(_ site: String) -> Bool {
        AgentSites.allowed(site, in: AgentSites.entries(app.settings[SettingKeys.agentSites])) != nil
    }

    /// Runs the action on the page, building the page's tab first if it wasn't built yet.
    private func browse(
        _ page: TabRef, in wid: String, _ action: BrowserAction, _ args: JSONValue, login: String? = nil
    ) async throws -> JSONValue {
        guard let tab = app.workbench.content(page, in: wid) as? BrowserTab else {
            throw RPCError.invalidParams("That tab shows no page.")
        }
        if let login { tab.loginSite = login }
        // Add where the page is, for the marks it shows outside its tab (`AgentPages`).
        var args = args
        if case .object(var fields) = args {
            fields["tab"] = .string(page.id)
            fields["workspace"] = .string(wid)
            args = .object(fields)
        }
        return try await tab.browse(action, args)
    }

    static var noPage: RPCError {
        RPCError.invalidParams("No page of yours open in this workspace: kelp browser open <url> first.")
    }

    /// After restore, the tab's URI is the record of its owner. Shared and legacy tabs carry no such record.
    static func ownPage(_ tabs: [TabRef], session: String, last: AgentPages.Visit?) -> TabRef? {
        func owns(_ tab: TabRef) -> Bool { TabURI.agentPageSession(tab.uri) == session }
        if let last, let tab = tabs.first(where: { $0.id == last.tab }) {
            if let site = last.sharedSite {
                return AgentSites.site(of: TabURI.pageURL(tab.uri)).map { AgentSites.covers(site, $0) } == true
                    ? tab : nil
            }
            if owns(tab) { return tab }
        }
        return tabs.first { owns($0) && !TabURI.pageURL($0.uri).isEmpty } ?? tabs.first(where: owns)
    }
}
