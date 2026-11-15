import Foundation

/// A group's arrangement kept to open others with (Save Layout as Template…): its panes and their sizes, the files and
/// pages they show, and what ran in them as what runs again (`agent:` and `terminal:` URIs, `TabURI.runs`), each
/// started anew in its tab when the template is used. Whether it opens in a window of its own.
public struct LayoutTemplate: Codable, Equatable {
    public var name: String
    public var layout: WorkspaceLayout
    public var ownWindow: Bool

    /// `running`: what runs again for a session's tab; nil leaves the tab out. Tabs that are only a moment's (an
    /// untitled file, a handed-over prompt, a subagent's journal) are left out too, and a pane left empty goes.
    public init(name: String, from layout: WorkspaceLayout, ownWindow: Bool, running: (String) -> String?) {
        self.name = name
        self.ownWindow = ownWindow
        var kept = layout
        for tab in layout.allTabs {
            let scheme = TabURI.scheme(tab.uri)
            if scheme == "session", let run = running(tab.uri) {
                kept.setURI(run, of: tab)   // by its tab: two Claudes are two `agent:claude` tabs
            } else if scheme == "session" || ["untitled", "prompt", "subagent"].contains(scheme) {
                kept.remove(tab.id)
            }
        }
        self.layout = kept
    }

    /// The tabs started anew when it's used, in order.
    public var runs: [TabRef] { layout.allTabs.filter { TabURI.runs($0.uri) } }

    /// The layout for a group using it: `started` gives the session URI each run became; a run that didn't start
    /// leaves its tab out.
    public func filled(_ started: [String: String]) -> WorkspaceLayout {
        var out = layout
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

extension WorkspaceLayout {
    fileprivate mutating func setURI(_ uri: String, of tab: TabRef) {
        guard let gid = group(of: tab.id), let i = groups[gid]?.tabs.firstIndex(of: tab) else { return }
        groups[gid]?.tabs[i].uri = uri
    }
}
