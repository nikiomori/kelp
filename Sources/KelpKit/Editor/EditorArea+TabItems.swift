// What an editor area's tab strip shows of a tab: a run's look, the folder of a tab with the same name, and a tab that
// isn't built yet.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension EditorArea {
    /// A run's tab (started from the Run menu) among the terminals: its purpose's symbol in colour, with a glow of that
    /// colour. Any session's tab shows the port it serves as a plain label; the title bar's capsule is what opens it.
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

    /// A tab an agent drives (a page, `TabProvider.driven`): the agent's logo for its icon, its card under the pointer,
    /// and a glow in its colour while it acts there.
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

    /// Strip entry for a tab not built yet, from its URI alone.
    /// Two files with one name (README.md twice): each tab adds its folder, "README.md — docs", as Xcode does.
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

    /// A tab not built yet, as its provider says it will look; an extension's view by its manifest, else its URI.
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
