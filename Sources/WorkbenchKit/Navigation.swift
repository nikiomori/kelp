import Core
import CoreGraphics
import Foundation

extension WorkspaceLayout {
    /// The tab `offset` steps from the selected one in the focused group, wrapping around (⌃Tab).
    public func tab(cycling offset: Int) -> String? {
        guard let focused = focusedGroup, let cur = focused.selectedTab, let index = focused.tabs.firstIndex(of: cur),
            !focused.tabs.isEmpty
        else {
            return nil
        }
        return focused.tabs[(index + offset % focused.tabs.count + focused.tabs.count) % focused.tabs.count].id
    }

    /// The selected tab of the pane `offset` steps from the focused one, wrapping around; nil with a single pane.
    public func tabInGroup(cycling offset: Int) -> String? {
        guard let ids = root?.sessions, let cur = focusedGroup?.id, let index = ids.firstIndex(of: cur), ids.count > 1
        else { return nil }
        return groups[ids[(index + offset % ids.count + ids.count) % ids.count]]?.selectedTab?.id
    }

    /// An open tab on the same file as `uri`, whatever line it was opened at.
    /// `real` names a path as the disk has it (the app passes realpath: /tmp/x is /private/tmp/x).
    public func fileTab(sameFileAs uri: String, real: (String) -> String = { $0 }) -> TabRef? {
        guard TabURI.scheme(uri) == "file" else { return nil }
        let path = real(TabURI.filePath(uri).path)
        return allTabs.first { TabURI.scheme($0.uri) == "file" && real(TabURI.filePath($0.uri).path) == path }
    }

    /// Returns the open tab of a web page: the tab at that address, or, for a local server's bare address, any page of
    /// that server, because a tab follows its navigation (`http://localhost:5173` finds the tab now at `/cart`).
    public func pageTab(for uri: String) -> TabRef? {
        guard ["http", "https"].contains(TabURI.scheme(uri)) else { return nil }
        if let exact = tab(uri: uri) { return exact }
        guard let address = URLComponents(string: uri), ["", "/"].contains(address.path),
            ["localhost", "127.0.0.1"].contains(address.host ?? "")
        else { return nil }
        return allTabs.first { tab in
            guard ["http", "https"].contains(TabURI.scheme(tab.uri)), let other = URLComponents(string: tab.uri) else {
                return false
            }
            return other.host == address.host && other.port == address.port
        }
    }

    /// Returns the pane on that side of `from` that is nearest by center (Ghostty's goto_split). Panes only touching
    /// the edge by
    /// 2 points or less still count as beside it. Window coordinates: y grows upward (`.maxY` is up).
    public static func nearestPane(from a: CGRect, among panes: [String: CGRect], toward edge: NSRectEdge) -> String? {
        panes.compactMap { id, b -> (String, CGFloat)? in
            let beyond =
                switch edge {
                case .minX: b.maxX <= a.minX + 2
                case .maxX: b.minX >= a.maxX - 2
                case .minY: b.maxY <= a.minY + 2
                default: b.minY >= a.maxY - 2
                }
            return beyond ? (id, hypot(b.midX - a.midX, b.midY - a.midY)) : nil
        }.min { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }?.0
    }
}

/// Workspaces in the order they were shown, for Back / Forward (⌃⌘← / ⌃⌘→), like a browser's history. It keeps at most
/// 50, and showing a workspace after going back drops what was ahead.
public struct WorkspaceHistory: Equatable, Sendable {
    public private(set) var visits: [String] = []
    public private(set) var at = -1
    public init() {}

    public mutating func visit(_ id: String) {
        visits = Array(visits.prefix(at + 1).suffix(49)) + [id]
        at = visits.count - 1
    }

    /// Returns where Back (-1) or Forward (1) goes, skipping workspaces that are gone and the one on screen. Returns
    /// nil when nothing is that way.
    public func target(_ step: Int, current: String?, exists: (String) -> Bool) -> Int? {
        var index = at + step
        while visits.indices.contains(index), !exists(visits[index]) || visits[index] == current { index += step }
        return visits.indices.contains(index) ? index : nil
    }

    /// Goes to `index` (from `target`) and returns which workspace that is.
    public mutating func go(to index: Int) -> String {
        at = index
        return visits[index]
    }
}

/// Returns a project's own screen: its oldest workspace, which its chats are on. That screen has no heading and doesn't
/// close, and every other workspace is a group.
public func mainWorkspace(of repo: Repo, among ws: [Worktree]) -> Worktree? {
    ws.filter { $0.repoId == repo.id && $0.path == repo.path && !$0.archived }.min { $0.createdAt < $1.createdAt }
}

/// Returns where a new chat in project `repo` goes: the screen you are on when it belongs to that project, or else the
/// project's own screen.
public func newChatScreen(in repo: Repo, current: Worktree?, rows: [Worktree]) -> Worktree? {
    if let current, current.repoId == repo.id { return current }
    return mainWorkspace(of: repo, among: rows) ?? rows.first { $0.repoId == repo.id && !$0.archived }
}

/// Decides what happens when several workspaces close at once (the sidebar's multi-selection). A project's own screen
/// stays. When a project has none and every open workspace was picked, the oldest picked one stays. A workspace in the
/// project's folder is removed, and a workspace on its own branch is archived.
public struct WorkspaceClosing: Equatable, Sendable {
    public private(set) var remove: [String] = [], archive: [String] = []
    /// Some picked workspaces stay, so their project keeps one.
    public private(set) var keptSome = false
    public var ids: [String] { remove + archive }

    /// `open` holds every workspace that isn't archived, and `repos` say where each project's folder is.
    public init(picked: [Worktree], open: [Worktree], repos: [Repo]) {
        var kept = Set<String>()
        for (repo, mine) in Dictionary(grouping: picked, by: \.repoId) {
            if let project = repos.first(where: { $0.id == repo }), let own = mainWorkspace(of: project, among: open) {
                if mine.contains(own) { kept.insert(own.id) }
            } else if mine.count >= open.filter({ $0.repoId == repo }).count,
                let oldest = mine.min(by: { $0.createdAt < $1.createdAt })
            {
                kept.insert(oldest.id)
            }
        }
        keptSome = !kept.isEmpty
        for w in picked where !kept.contains(w.id) {
            if w.path == repos.first(where: { $0.id == w.repoId })?.path {
                remove.append(w.id)
            } else {
                archive.append(w.id)
            }
        }
    }

    /// Called when the last tab of `worktree` closed and nothing runs there, so its row goes too. Returns the row to
    /// show instead: the one under it, or else the one over it. Returns nil when the workspace stays because it is the
    /// project's own screen. `rows` holds the project's open workspaces, as the sidebar lists them.
    public static func afterLastTab(of worktree: Worktree, rows: [Worktree], repos: [Repo]) -> Worktree? {
        guard let project = repos.first(where: { $0.id == worktree.repoId }),
            worktree.id != mainWorkspace(of: project, among: rows)?.id,
            let index = rows.firstIndex(where: { $0.id == worktree.id })
        else { return nil }
        return rows.dropFirst(index + 1).first ?? rows[..<index].last
    }
}

/// The list that ⌃Tab cycles through, ordered like ⌘Tab's. The screen you're on comes first, then the others by when
/// they were last on screen, then those never on screen by their agents' last activity, newest first. Each entry is a
/// workspace's id or a server's page ("host:<name>"). Anything not in `live` (closed, archived, a server no project is
/// on anymore) is left out.
public enum RecentScreens {
    public static func order(
        current: String?, recent: [String], stirred: [(id: String, at: Date)], live: Set<String>
    ) -> [String] {
        var out: [String] = []
        let rest = stirred.sorted { $0.at > $1.at }.map(\.id)
        for id in [current].compactMap({ $0 }) + recent + rest where live.contains(id) && !out.contains(id) {
            out.append(id)
        }
        return out
    }
}
