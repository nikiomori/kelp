import AppKit
import Core
import WorkbenchKit

/// `kelp browser`: an agent's command, done in a page tab of its workspace. That workspace needn't be on screen, only
/// loaded (shown lately): its tabs live on while another one is shown.
extension UIRequests {
    func browse(_ e: UIBrowserEvent) {
        Task {
            let reply: UIBrowserReply
            do { reply = UIBrowserReply(request: e.request, result: try await run(e)) } catch {
                reply = UIBrowserReply(request: e.request, error: AppModel.message(error))
            }
            _ = await app.quiet(reply)   // the daemon went: nobody is waiting for it
        }
    }

    private func run(_ e: UIBrowserEvent) async throws -> JSONValue {
        guard let wid = e.worktreeId ?? app.workbench.workspaceId else {
            throw RPCError.invalidParams("No workspace to open a page in.")
        }
        guard let area = app.workbench.window?.editors.area(wid) else {
            throw RPCError.invalidParams("This workspace isn't open in Kelp's window: show it once, then try again.")
        }
        let args = e.args ?? .object([:])
        if e.action == "open", let t = try await area.pageForOpen(shared: args["shared"]?.bool == true, args: args) {
            return try await area.browse(t, "info", args)
        }
        guard let t = area.browsedPage() else {
            throw RPCError.invalidParams("No page of yours open in this workspace: kelp browser open <url> first.")
        }
        return try await area.browse(t, e.action, args)
    }
}

extension EditorArea {
    /// A new page tab for `open`, beside the agent's pane; nil when there's one to navigate already: the page it drove, or
    /// an agent's own, of the kind asked (`shared`: the user's cookies, which only a plain page has). A shared one acts as
    /// the user, so the user says so first.
    func pageForOpen(shared: Bool, args: JSONValue) async throws -> TabRef? {
        let url = args["url"]?.string ?? ""
        // A shared page is the one site the user allowed: another site is asked for again, in a tab of its own.
        if let t = ownPage(), shared == (TabURI.scheme(t.uri) != TabURI.agentScheme),
            !shared || url.isEmpty
                || PageOrigin.of(URL(string: url)) == PageOrigin.of(URL(string: TabURI.pageURL(t.uri)))
        {
            return nil
        }
        guard !url.isEmpty else { return nil }
        if shared, await !Self.allowShared(url) {
            throw RPCError.invalidParams(
                "The user didn't let you use their logged-in browser: kelp browser open without --shared.")
        }
        let uri = shared ? url : TabURI.agentPage(url)
        if app.workbench.window?.editors.current === self {
            showAside(uri, split: .right)
        } else {
            open(uri, split: .right, focus: false)
        }
        guard let t = layout.tab(uri: uri) ?? layout.pageTab(for: uri) else { return nil }
        browsing = t.id
        return t
    }

    /// The page `kelp browser` drives here: one it opened. The user's own page tabs carry their logins, so an agent never
    /// takes one of those by itself.
    func browsedPage() -> TabRef? {
        let t = ownPage()
        browsing = t?.id
        return t
    }

    /// Asked before `open --shared`: the page gets the user's cookies, and what the agent does there it does as them.
    private static func allowShared(_ url: String) async -> Bool {
        let a = NSAlert()
        a.messageText = String(localized: "Let an agent use your logged-in browser?")
        a.informativeText = String(localized: "It opens \(url) with your cookies and can act as you on that site.")
        a.addButton(withTitle: String(localized: "Allow"))
        a.addButton(withTitle: String(localized: "Don't Allow"))
        return await runSheet(a) == .alertFirstButtonReturn
    }

    /// The action, by the tab's provider, on the tab, built if it wasn't yet.
    func browse(_ t: TabRef, _ action: String, _ args: JSONValue) async throws -> JSONValue {
        guard let tab = content(t), let browse = app.extensions.tabProvider(for: t.uri)?.browse else {
            throw RPCError.invalidParams("That tab shows no page.")
        }
        return try await browse(tab, action, args)
    }

    /// The page it drove last (one it opened: `browsing` is set only by `open` and by this), else an agent's own.
    private func ownPage() -> TabRef? {
        layout.allTabs.first { $0.id == browsing && TabURI.isPage($0.uri) }
            ?? layout.allTabs.first { TabURI.scheme($0.uri) == TabURI.agentScheme }
    }
}
