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
    /// and a commit's draft are left out too, and a pane left empty goes.
    public init(
        name: String, from layout: WorkspaceLayout, in place: Place, ownWindow: Bool, running: (String) -> String?
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
            } else {
                kept.setURI(Self.abstract(tab.uri, from: place), of: tab)
            }
        }
        self.layout = kept
    }

    /// The tabs started anew when it's used, in order.
    public var runs: [TabRef] { layout.allTabs.filter { TabURI.runs($0.uri) } }

    /// The layout for group `place` using it: `started` gives the session URI each run became; a run that didn't start
    /// leaves its tab out.
    public func filled(_ started: [String: String], in place: Place) -> WorkspaceLayout {
        var out = layout
        for tab in layout.allTabs where !TabURI.runs(tab.uri) { out.setURI(Self.placed(tab.uri, in: place), of: tab) }
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
    static let groupToken = "{group}", folderToken = "{folder}"

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
