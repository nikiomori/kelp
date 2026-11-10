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

    func placeholder(_ tab: TabRef) -> TabStrip.Item {
        let body = TabURI.body(tab.uri)
        switch TabURI.scheme(tab.uri) {
        case "session":
            let session = app.session(body)
            let title = session.map(app.catalog.displayName) ?? String(localized: "Session")
            return .init(
                id: tab.id, title: title, icon: app.catalog.icon(session?.agent),
                status: session.flatMap { $0.agent == "shell" ? nil : $0.endedWithError ? .error : $0.status },
                unread: session?.unread ?? false, toolTip: title)
        case "file":
            let path = TabURI.filePath(tab.uri).path
            return .init(
                id: tab.id, title: (path as NSString).lastPathComponent,
                icon: app.fileIcons.image((path as NSString).lastPathComponent),
                status: nil, toolTip: path)
        case "diff":
            return .init(
                id: tab.id, title: String(localized: "Changes"), icon: .symbol("plus.forwardslash.minus"), status: nil,
                toolTip: nil)
        case "http", "https", "about", TabURI.agentScheme:
            return .init(
                id: tab.id, title: URL(string: TabURI.pageURL(tab.uri))?.host ?? String(localized: "New Page"),
                icon: .symbol("safari"),
                status: nil, toolTip: tab.uri)
        case "preview":
            return .init(
                id: tab.id, title: (body as NSString).lastPathComponent, icon: .symbol("eye"), status: nil,
                toolTip: body)
        case "usage":
            return .init(
                id: tab.id, title: String(localized: "Usage"), icon: .symbol("chart.bar"), status: nil, toolTip: nil)
        case "routines":
            return .init(
                id: tab.id, title: String(localized: "Routines"), icon: .symbol("clock.arrow.circlepath"), status: nil,
                toolTip: nil)
        case "cilog":
            return .init(
                id: tab.id, title: String(localized: "Log"), icon: .symbol("doc.text"), status: nil, toolTip: nil)
        case "db":   // "<workspace>/<name>[?table=<t>|?run=<id>]": as the tab will title itself
            let parts = body.split(separator: "?", maxSplits: 1).map(String.init)
            let name =
                parts[0].split(separator: "/", maxSplits: 1).last.map {
                    String($0).removingPercentEncoding ?? String($0)
                } ?? body
            let table =
                parts.count > 1 && parts[1].hasPrefix("table=")
                ? String(parts[1].dropFirst(6)).removingPercentEncoding : nil
            return .init(
                id: tab.id, title: table.map { "\($0) · \(name)" } ?? name, icon: .symbol("cylinder.split.1x2"),
                status: nil, toolTip: nil)
        default:
            let info = app.extensions.viewInfo(tab.uri)
            return .init(
                id: tab.id, title: info?.title ?? body, icon: .symbol(info?.icon ?? "puzzlepiece.extension"),
                status: nil,
                toolTip: tab.uri)
        }
    }
}

extension TabStrip.Item {
    /// `p`'s name, icon and tip, with what a tab's badge says.
    static func badged(_ p: TabStrip.Item, _ b: TabBadge?, edited: Bool = false) -> TabStrip.Item {
        TabStrip.Item(
            id: p.id, title: p.title, icon: p.icon, status: b?.status, unread: b?.unread ?? false, toolTip: p.toolTip,
            edited: edited,
            meter: b?.meter, progress: b?.progress, background: b?.background ?? 0, backgroundTip: b?.backgroundTip,
            waitsFor: b?.waitsFor ?? false)
    }
}
