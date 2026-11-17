// What an editor area's tab strip shows of a tab: a run's look, the folder of a tab with the same name, and a tab that
// isn't built yet.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension EditorArea {
    /// Gives a run's tab (started from the Run menu) its look among the terminals: the symbol of its purpose in colour,
    /// with a glow of that colour. Any session's tab shows the port it serves as a plain label; the capsule in the
    /// title bar is what opens it.
    func runLook(_ item: TabStrip.Item, _ tab: TabRef) -> TabStrip.Item {
        if let driven = app.extensions.tabProvider(for: tab.uri)?.driven { return drivenLook(item, tab, driven) }
        guard TabURI.scheme(tab.uri) == "session", let session = app.session(TabURI.body(tab.uri)),
            session.status != .exited
        else {
            return item
        }
        var item = item
        if !session.isTerminal { item.card = .agent(session.id) }   // an agent's tab shows the sidebar's card; a terminal keeps its tooltip
        let runs = app.extensions.all.runs
        if let look = runs?.look(session) {
            item.icon = look.icon
            item.run = look.glow
        }
        if let port = runs?.port(session) { item.title += " · :\(port)" }
        return item
    }

    /// Gives a tab an agent drives (a page, `TabProvider.driven`) the agent's logo as its icon, the agent's card under
    /// the pointer, and a glow in the agent's colour while it acts there.
    func drivenLook(
        _ item: TabStrip.Item, _ tab: TabRef,
        _ driven: @MainActor (String) -> [String: (session: String, glow: NSColor?)]
    ) -> TabStrip.Item {
        guard let by = driven(workspaceId)[tab.id], let session = app.session(by.session) else { return item }
        var item = item
        item.icon = app.catalog.icon(session.agent, size: 14) ?? item.icon
        item.card = .agent(session.id)
        item.run = by.glow
        return item
    }

    /// Tells apart the tabs of two files with one name (README.md twice): each such tab adds its folder,
    /// "README.md — docs", as Xcode does.
    static func disambiguated(_ items: [TabStrip.Item], _ tabs: [TabRef]) -> [TabStrip.Item] {
        let paths = tabs.map { TabURI.scheme($0.uri) == "file" ? TabURI.filePath($0.uri).path as NSString : nil }
        let names = paths.map { $0?.lastPathComponent }
        return zip(items, paths).map { item, path in
            // A tab named otherwise (an agent's page by its title) is told apart by that name already.
            guard let path, item.title == path.lastPathComponent,
                names.filter({ $0 == path.lastPathComponent }).count > 1
            else { return item }
            var item = item
            item.title = path.lastPathComponent + " — " + (path.deletingLastPathComponent as NSString).lastPathComponent
            item.keepsEnd = true
            return item
        }
    }

    /// The strip entry for a tab not built yet, as its provider says it will look. Without a provider's placeholder,
    /// an extension's view shows as its manifest says, and any other tab shows its URI.
    func placeholder(_ tab: TabRef) -> TabStrip.Item {
        if let look = app.extensions.tabProvider(for: tab.uri)?.placeholder?(tab.uri) {
            return .init(id: tab.id, title: look.title, icon: look.icon, toolTip: look.toolTip)
        }
        let info = app.extensions.viewInfo(tab.uri)
        return .init(
            id: tab.id, title: info?.title ?? TabURI.body(tab.uri),
            icon: .symbol(info?.icon ?? "puzzlepiece.extension"), toolTip: tab.uri)
    }
}
