import Foundation

/// A group's arrangement kept to open others with (Save Layout as Template…): its panes and their sizes, the files and
/// pages they show, and what ran in them as what runs again (`agent:` and `terminal:` URIs, `TabURI.runs`), each
/// started anew in its tab when the template is used. Whether it opens in a window of its own.
public struct LayoutTemplate: Codable, Equatable {
    public var name: String
    public var layout: WorkspaceLayout
    public var ownWindow: Bool

    /// Where a template is saved from or used in: the group whose own addresses (its databases' and changes' tabs, files
    /// in its folder) it keeps as the group's, not as that one's.
    public struct Place {
        public var workspace: String, folder: String
        public init(workspace: String, folder: String) {
            self.workspace = workspace
            self.folder = folder
        }
    }

    /// `running`: what runs again for a session's tab; nil leaves the tab out. Tabs that are only a moment's (an
    /// untitled file, a handed-over prompt, a subagent's journal), an agent's own page (its logins are its own), a CI log
    /// and a commit's draft are left out too, and a pane left empty goes. `ports`: the port each session's tab (by its
    /// URI) serves: a page on one is kept as that run's page, whatever port it gets next time.
    public init(
        name: String, from layout: WorkspaceLayout, in place: Place, ownWindow: Bool, ports: [String: Int] = [:],
        running: (String) -> String?
    ) {
        self.name = name
        self.ownWindow = ownWindow
        var kept = layout
        for tab in layout.allTabs {
            let scheme = TabURI.scheme(tab.uri)
            if scheme == "session", let run = running(tab.uri) {
                kept.setURI(run, of: tab)   // by its tab: two Claudes are two `agent:claude` tabs
            } else if scheme == "session" || Self.leftOut.contains(scheme) {
                kept.remove(tab.id)
            } else if let page = Self.localPage(tab.uri),
                let run = layout.allTabs.first(where: { ports[$0.uri] == page.port && running($0.uri) != nil })
            {
                kept.setURI("\(Self.runPage):\(run.id)\(page.rest)", of: tab)
            } else {
                kept.setURI(Self.abstract(tab.uri, from: place), of: tab)
            }
        }
        self.layout = kept
    }

    /// A project's own, from its .kelp.yaml (`layout.<name>: claude | page / run`): panes side by side with "|", one
    /// under another with " / " (spaces round it: a path has none), tabs in a pane with commas. A tab is an agent
    /// (`agents`), `shell`, one of the project's commands by name (`commands`; run by name, `scripts.run`, so the daemon
    /// checks the file's trust and runs its text as it is then), `page` (the first command's page, once it serves),
    /// `changes`, or a file in the group's folder. Kept as written: the group isn't tiled again (`manual`).
    public init(name: String, spec: String, agents: Set<String>, commands: Set<String>) {
        self.name = name
        ownWindow = false
        var layout = WorkspaceLayout(), wantsPage: [TabRef] = [], firstRun: TabRef?
        func parts(_ text: String, _ by: String) -> [String] {
            text.components(separatedBy: by).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let columns: [LayoutNode] = parts(spec, "|").compactMap { column in
            let panes: [LayoutNode] = parts(column, " / ").map { pane in
                var group = GroupModel()
                for item in parts(pane, ",") {
                    var tab = TabRef(uri: "")
                    if agents.contains(item) {
                        tab.uri = TabURI.agent(item)
                    } else if ["shell", "terminal"].contains(item) {
                        tab.uri = TabURI.terminal()
                    } else if commands.contains(item) {
                        tab.uri = TabURI.terminal(["script": item, "title": item])
                        firstRun = firstRun ?? tab
                    } else if item == "page" {
                        wantsPage.append(tab)
                    } else if item == "changes" {
                        tab.uri = "diff:" + Self.groupToken
                    } else {
                        tab.uri = TabURI.file(Self.folderToken) + "/" + TabURI.file(item).dropFirst("file://".count)
                    }
                    group.tabs.append(tab)
                }
                layout.groups[group.id] = group
                return .pane(group.id)
            }
            return panes.count > 1 ? .split(vertical: false, children: panes) : panes.first
        }
        layout.root = columns.count > 1 ? .split(vertical: true, children: columns) : columns.first
        layout.focused = layout.root?.sessions.first
        layout.manual = true
        for tab in wantsPage {
            if let firstRun { layout.setURI("\(Self.runPage):\(firstRun.id)", of: tab) } else { layout.remove(tab.id) }
        }
        self.layout = layout
    }

    /// The tabs started anew when it's used, in order.
    public var runs: [TabRef] { layout.allTabs.filter { TabURI.runs($0.uri) } }

    /// The pages of its runs: each opens in its tab once its run (a tab's id) serves, at `path` on the port it has then.
    public var pages: [(tab: TabRef, run: String, path: String)] {
        layout.allTabs.filter { TabURI.scheme($0.uri) == Self.runPage }.map { tab in
            let body = TabURI.body(tab.uri), cut = body.firstIndex { "/?#".contains($0) } ?? body.endIndex
            return (tab, String(body[..<cut]), String(body[cut...]))
        }
    }
    /// What a run's page's tab shows until the run serves.
    public static func waiting(_ tab: TabRef) -> String { "about:blank#" + tab.id }

    /// The layout for group `place` using it: `started` gives the session URI each run became; a run that didn't start
    /// leaves its tab out.
    public func filled(_ started: [String: String], in place: Place) -> WorkspaceLayout {
        var out = layout
        for tab in layout.allTabs where !TabURI.runs(tab.uri) {
            if TabURI.scheme(tab.uri) != Self.runPage {
                out.setURI(Self.placed(tab.uri, in: place), of: tab)
            } else if pages.contains(where: { $0.tab == tab && started[$0.run] != nil }) {
                out.setURI(Self.waiting(tab), of: tab)   // a blank page keeps its pane until the run serves
            } else {
                out.remove(tab.id)
            }
        }
        for tab in runs {
            if let session = started[tab.id] {
                out.setURI(session, of: tab)
            } else {
                out.remove(tab.id)
            }
        }
        return out
    }
}

extension LayoutTemplate {
    static let leftOut = ["untitled", "prompt", "subagent", TabURI.agentScheme, "cilog", "commit"]
    static let groupToken = "{group}", folderToken = "{folder}", runPage = "runpage"

    /// A page on this Mac: its port, and what follows it in its address.
    static func localPage(_ uri: String) -> (port: Int, rest: String)? {
        guard let c = URLComponents(string: uri), c.scheme == "http", ["localhost", "127.0.0.1"].contains(c.host),
            let port = c.port, let at = uri.range(of: ":\(port)")
        else { return nil }
        return (port, String(uri[at.upperBound...]))
    }

    /// The group's own addresses as the group's: `db:<group>/…`, `diff:<group>…`, a file in its folder.
    static func abstract(_ uri: String, from place: Place) -> String {
        let folder = TabURI.file(place.folder) + "/"
        if uri.hasPrefix(folder) { return TabURI.file(folderToken) + "/" + uri.dropFirst(folder.count) }
        for scheme in ["db:", "diff:"] where uri.hasPrefix(scheme + place.workspace) {
            return scheme + groupToken + uri.dropFirst(scheme.count + place.workspace.count)
        }
        return uri
    }

    static func placed(_ uri: String, in place: Place) -> String {
        let folder = TabURI.file(folderToken) + "/"
        if uri.hasPrefix(folder) { return TabURI.file(place.folder) + "/" + uri.dropFirst(folder.count) }
        return uri.replacingOccurrences(of: groupToken, with: place.workspace)
    }
}

extension WorkspaceLayout {
    fileprivate mutating func setURI(_ uri: String, of tab: TabRef) {
        guard let gid = group(of: tab.id), let i = groups[gid]?.tabs.firstIndex(of: tab) else { return }
        groups[gid]?.tabs[i].uri = uri
    }
}
