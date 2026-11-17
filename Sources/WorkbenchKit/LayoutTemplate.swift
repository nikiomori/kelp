import Foundation

/// A group's arrangement, kept so that other groups can open with it (Save Layout as Template…). It holds the panes and
/// their sizes, the files and pages they show, and what ran in them as what runs again (`agent:` and `terminal:` URIs,
/// `TabURI.runs`), each started anew in its tab when the template is used. It also says whether the group opens in a
/// window of its own.
public struct LayoutTemplate: Codable, Equatable {
    public var name: String
    public var layout: WorkspaceLayout
    public var ownWindow: Bool

    /// The group a template is saved from or used in. The template keeps that group's own addresses (its database and
    /// changes tabs, files in its folder) as belonging to whichever group uses it, not to that particular group.
    public struct Place {
        public var workspace: String, folder: String
        public init(workspace: String, folder: String) {
            self.workspace = workspace
            self.folder = folder
        }
    }

    /// Saves a template from `layout`. `running` says what runs again for a session's tab, and nil leaves the tab out.
    /// Also left out are tabs that only matter for a moment (an untitled file, a handed-over prompt, a subagent's
    /// journal), an agent's own page (its logins are its own), a CI log and a commit's draft. A pane left empty is
    /// removed. `ports` gives the port that each session's tab (by its URI) serves, so a page on that port is kept as
    /// that run's page, whatever port the run gets next time.
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
                kept.setURI(run, of: tab)   // set by tab, because two Claudes are two `agent:claude` tabs
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

    /// A project's own template, from its .kelp.yaml (`layout.<name>: claude | page / run`). "|" puts panes side by
    /// side, " / " puts one under another (with spaces around it, because a path has none), and commas separate the
    /// tabs in a pane. A tab is an agent (`agents`), `shell`, one of the project's commands by name (`commands`),
    /// `page` (the first command's page, once it serves), `changes`, or a file in the group's folder. A command runs by
    /// name (`scripts.run`), so the daemon checks the file's trust and runs the command's text as it is then. The
    /// layout is kept as written, and the group isn't tiled again (`manual`).
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

    /// The tabs started anew when the template is used, in order.
    public var runs: [TabRef] { layout.allTabs.filter { TabURI.runs($0.uri) } }

    /// The pages of the template's runs. Each opens in its tab once its run (a tab's id) serves, at `path` on the port
    /// the run has then.
    public var pages: [(tab: TabRef, run: String, path: String)] {
        layout.allTabs.filter { TabURI.scheme($0.uri) == Self.runPage }.map { tab in
            let body = TabURI.body(tab.uri), cut = body.firstIndex { "/?#".contains($0) } ?? body.endIndex
            return (tab, String(body[..<cut]), String(body[cut...]))
        }
    }
    /// What the tab of a run's page shows until the run serves.
    public static func waiting(_ tab: TabRef) -> String { "about:blank#" + tab.id }

    /// Returns the layout for group `place` when it uses the template. `started` gives the session URI that each run
    /// became, and a run that didn't start leaves its tab out.
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

    /// Returns the port of a page on this Mac, and what follows the port in its address.
    static func localPage(_ uri: String) -> (port: Int, rest: String)? {
        guard let components = URLComponents(string: uri), components.scheme == "http",
            ["localhost", "127.0.0.1"].contains(components.host),
            let port = components.port, let at = uri.range(of: ":\(port)")
        else { return nil }
        return (port, String(uri[at.upperBound...]))
    }

    /// Replaces the group's own addresses with placeholders for whichever group uses the template: `db:<group>/…`,
    /// `diff:<group>…`, and files in its folder.
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
