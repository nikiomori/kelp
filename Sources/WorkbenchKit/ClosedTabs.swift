import Foundation

/// A tab closed by hand, and where it stood.
public struct ClosedTab: Equatable, Sendable {
    public let uri: String, title: String
    public internal(set) var workspace: String
    /// The tab's pane (which may be gone by the time the tab comes back) and its place among the pane's tabs.
    public let group: String?, index: Int?
    public let at: Date
    public init(uri: String, title: String, workspace: String, group: String?, index: Int?, at: Date = Date()) {
        self.uri = uri
        self.title = title
        self.workspace = workspace
        self.group = group
        self.index = index
        self.at = at
    }
    /// A file counts as one tab, whatever line it was open at.
    fileprivate var key: String { TabURI.scheme(uri) == "file" ? TabURI.filePath(uri).path : uri }
}

/// The last tabs closed while Kelp runs, latest first. After a restart, Session History has the conversations.
public struct ClosedTabs: Equatable, Sendable {
    public static let limit = 20
    public private(set) var all: [ClosedTab] = []
    public init() {}

    public mutating func remember(_ closedTab: ClosedTab) {
        all.removeAll { $0.key == closedTab.key && $0.workspace == closedTab.workspace }
        all.insert(closedTab, at: 0)
        if all.count > Self.limit { all.removeLast(all.count - Self.limit) }
    }
    public mutating func forget(_ closedTab: ClosedTab) { all.removeAll { $0 == closedTab } }
    /// Called when a workspace's row went away with its last tab. The tabs closed there come back on the row shown
    /// instead.
    public mutating func move(from workspace: String, to other: String) {
        for i in all.indices where all[i].workspace == workspace { all[i].workspace = other }
    }
}
