import AppKit
import Core
import WorkbenchKit

/// `kelp browser`: an agent's command, done in a page tab of its workspace. That workspace needn't be on screen, only
/// loaded (shown lately): its tabs live on while another one is shown.
extension UIRequests {
    func browse(_ e: UIBrowserEvent) {
        Task {
            let reply: UIBrowserReply
            do { reply = UIBrowserReply(request: e.request, result: try await run(e)) }
            catch { reply = UIBrowserReply(request: e.request, error: AppModel.message(error)) }
            _ = await app.quiet(reply)   // the daemon went: nobody is waiting for it
        }
    }

    private func run(_ e: UIBrowserEvent) async throws -> JSONValue {
        guard let wid = e.worktreeId ?? app.workbench.workspaceId else { throw RPCError.invalidParams("No workspace to open a page in.") }
        guard let area = app.workbench.window?.editors.area(wid) else {
            throw RPCError.invalidParams("This workspace isn't open in Kelp's window: show it once, then try again.")
        }
        let args = e.args ?? .object([:])
        if e.action == "open", let t = area.pageForOpen(shared: args["shared"]?.bool == true, args: args) {
            return try await area.browse(t, "info", args)
        }
        guard let t = area.browsedPage() else { throw RPCError.invalidParams("No page open in this workspace: kelp browser open <url> first.") }
        return try await area.browse(t, e.action, args)
    }
}

extension EditorArea {
    /// A new page tab for `open`, beside the agent's pane; nil when there's one to navigate already: the page it drove, or
    /// an agent's own, of the kind asked (`shared`: the user's cookies, which only a plain page has).
    func pageForOpen(shared: Bool, args: JSONValue) -> TabRef? {
        if let t = ownPage(), shared == (TabURI.scheme(t.uri) != TabURI.agentScheme) { return nil }
        guard let url = args["url"]?.string, !url.isEmpty else { return nil }
        let uri = shared ? url : TabURI.agentPage(url)
        if app.workbench.window?.editors.current === self { showAside(uri, split: .right) } else { open(uri, split: .right, focus: false) }
        guard let t = layout.tab(uri: uri) ?? layout.pageTab(for: uri) else { return nil }
        browsing = t.id
        return t
    }

    /// The page `kelp browser` drives here: its own, else one on screen, else any.
    func browsedPage() -> TabRef? {
        let pages = layout.allTabs.filter { TabURI.isPage($0.uri) }
        let shown = Set(layout.groups.values.compactMap(\.selectedTab?.id))
        let t = ownPage() ?? pages.first { shown.contains($0.id) } ?? pages.first
        browsing = t?.id
        return t
    }

    /// The action, by the tab's provider, on the tab, built if it wasn't yet.
    func browse(_ t: TabRef, _ action: String, _ args: JSONValue) async throws -> JSONValue {
        guard let tab = content(t), let browse = app.extensions.tabProvider(for: t.uri)?.browse else {
            throw RPCError.invalidParams("That tab shows no page.")
        }
        return try await browse(tab, action, args)
    }

    /// The page it drove last, else an agent's own.
    private func ownPage() -> TabRef? {
        layout.allTabs.first { $0.id == browsing && TabURI.isPage($0.uri) } ?? layout.allTabs.first { TabURI.scheme($0.uri) == TabURI.agentScheme }
    }
}
