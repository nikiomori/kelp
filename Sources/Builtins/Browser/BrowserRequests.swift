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
            return try await browse(page, in: wid, action, args)
        }

        guard let url = args["url"]?.string, !url.isEmpty else { throw RPCError.invalidParams("open needs url") }
        if args["shared"]?.bool == true {
            guard !remote, subagent == nil else {
                throw RPCError.invalidParams("Use kelp browser open without --shared from a subagent or remote host.")
            }
            guard let site = Self.sharedSite(url) else {
                throw RPCError.invalidParams("open --shared needs an HTTP or HTTPS site.")
            }
            if let page, last?.tab == page.id, last?.sharedSite == site {
                return try await browse(page, in: wid, .open, args)
            }
            let caller = session.flatMap { app.session($0)?.displayTitle } ?? String(localized: "This browser command")
            guard await Self.allowShared(site, caller: caller) else {
                throw RPCError.invalidParams(
                    "The user didn't let you use their logged-in browser: kelp browser open without --shared.")
            }
            guard let page = app.workbench.openBeside(url, in: wid, reuse: false) else { throw Self.noPage }
            pages.browsed[scope] = AgentPages.Visit(tab: page.id, sharedSite: site)
            return try await browse(page, in: wid, .info, args)
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

    private static func allowShared(_ site: String, caller: String) async -> Bool {
        await confirm(
            String(localized: "Let an agent use your logged-in browser?"),
            detail: String(localized: "\(caller) can act as you on \(site) using your cookies."),
            action: String(localized: "Allow"), cancel: String(localized: "Don’t Allow"))
    }

    /// Runs the action on the page, building the page's tab first if it wasn't built yet.
    private func browse(_ page: TabRef, in wid: String, _ action: BrowserAction, _ args: JSONValue) async throws
        -> JSONValue
    {
        guard let tab = app.workbench.content(page, in: wid) as? BrowserTab else {
            throw RPCError.invalidParams("That tab shows no page.")
        }
        if action != .open, tab.ownerSession?.hasPrefix(AgentPages.remotePrefix) == true, tab.hostChip.isHidden {
            throw Self.noPage
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

    static var noPage: RPCError {
        RPCError.invalidParams("No page of yours open in this workspace: kelp browser open <url> first.")
    }

    private static func sharedSite(_ url: String) -> String? {
        guard ["http", "https"].contains(TabURI.scheme(url)) else { return nil }
        return PageOrigin.of(URL(string: url))
    }

    /// After restore, the tab's URI is the record of its owner. Shared and legacy tabs carry no such record.
    static func ownPage(_ tabs: [TabRef], session: String, last: AgentPages.Visit?) -> TabRef? {
        func owns(_ tab: TabRef) -> Bool { TabURI.agentPageSession(tab.uri) == session }
        if let last, let tab = tabs.first(where: { $0.id == last.tab }) {
            if let site = last.sharedSite { return sharedSite(tab.uri) == site ? tab : nil }
            if owns(tab) { return tab }
        }
        return tabs.first { owns($0) && !TabURI.pageURL($0.uri).isEmpty } ?? tabs.first(where: owns)
    }
}
