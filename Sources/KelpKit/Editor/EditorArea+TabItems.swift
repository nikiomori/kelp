// What an editor area's tab strip shows of a tab: a run's look, a namesake's folder, a tab not built yet.
import AppKit
import Core
import DesignKit
import WorkbenchKit

extension EditorArea {
    /// A run's tab (the Run menu's) among the terminals: its purpose's symbol in colour and a glow of that colour. Any
    /// session's tab says the port it serves, a label only: the title bar's capsule opens it.
    func runLook(_ item: TabStrip.Item, _ tab: TabRef) -> TabStrip.Item {
        guard TabURI.scheme(tab.uri) == "session", let session = app.session(TabURI.body(tab.uri)),
            session.status != .exited
        else {
            return item
        }
        var item = item
        if session.agent != "shell" { item.card = "a:" + session.id }   // an agent's tab shows the sidebar's card; a terminal keeps its tooltip
        let runs = app.extensions.all.runs
        if let look = runs?.look(session) {
            item.icon = look.icon
            item.run = look.glow
        }
        if let port = runs?.port(session) { item.title += " · :\(port)" }
        return item
    }

    /// Strip entry for a tab not built yet, from its URI alone.
    /// Two files with one name (README.md twice): each tab adds its folder, "README.md — docs", as Xcode does.
    static func disambiguated(_ items: [TabStrip.Item], _ tabs: [TabRef]) -> [TabStrip.Item] {
        let paths = tabs.map { TabURI.scheme($0.uri) == "file" ? TabURI.filePath($0.uri).path as NSString : nil }
        let names = paths.map { $0?.lastPathComponent }
        return zip(items, paths).map { item, path in
            guard let path, names.filter({ $0 == path.lastPathComponent }).count > 1 else { return item }
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
