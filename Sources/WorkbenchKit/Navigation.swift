import Foundation
import CoreGraphics
import Core

extension WorkspaceLayout {
    /// The tab `offset` steps from the selected one in the focused group, wrapping around (⌃Tab).
    public func tab(cycling offset: Int) -> String? {
        guard let g = focusedGroup, let cur = g.selectedTab, let i = g.tabs.firstIndex(of: cur), !g.tabs.isEmpty else { return nil }
        return g.tabs[(i + offset % g.tabs.count + g.tabs.count) % g.tabs.count].id
    }

    /// The selected tab of the pane `offset` steps from the focused one, wrapping around; nil with a single pane.
    public func tabInGroup(cycling offset: Int) -> String? {
        guard let ids = root?.sessions, let cur = focusedGroup?.id, let i = ids.firstIndex(of: cur), ids.count > 1 else { return nil }
        return groups[ids[(i + offset % ids.count + ids.count) % ids.count]]?.selectedTab?.id
    }

    /// An open tab on the same file as `uri`, whatever line it was opened at.
    public func fileTab(sameFileAs uri: String) -> TabRef? {
        guard TabURI.scheme(uri) == "file" else { return nil }
        let path = TabURI.filePath(uri).path
        return allTabs.first { TabURI.scheme($0.uri) == "file" && TabURI.filePath($0.uri).path == path }
    }

    /// The pane on that side of `from`, the nearest by center (Ghostty's goto_split). Panes only touching the edge by
    /// 2 points or less still count as beside it. Window coordinates: y grows upward (`.maxY` is up).
    public static func nearestPane(from a: CGRect, among panes: [String: CGRect], toward edge: NSRectEdge) -> String? {
        panes.compactMap { id, b -> (String, CGFloat)? in
            let beyond = switch edge {
            case .minX: b.maxX <= a.minX + 2
            case .maxX: b.minX >= a.maxX - 2
            case .minY: b.maxY <= a.minY + 2
            default: b.minY >= a.maxY - 2
            }
            return beyond ? (id, hypot(b.midX - a.midX, b.midY - a.midY)) : nil
        }.min { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }?.0
    }
}

/// Workspaces in the order they were shown, for Back / Forward (⌃⌘← / ⌃⌘→), like a browser's history: at most 50, and
/// showing one after going back drops what was ahead.
public struct WorkspaceHistory: Equatable, Sendable {
    public private(set) var visits: [String] = []
    public private(set) var at = -1
    public init() {}

    public mutating func visit(_ id: String) {
        visits = Array(visits.prefix(at + 1).suffix(49)) + [id]
        at = visits.count - 1
    }

    /// Where Back (-1) / Forward (1) goes: past workspaces that are gone and the one on screen; nil when nothing is that way.
    public func target(_ step: Int, current: String?, exists: (String) -> Bool) -> Int? {
        var i = at + step
        while visits.indices.contains(i), !exists(visits[i]) || visits[i] == current { i += step }
        return visits.indices.contains(i) ? i : nil
    }

    /// Goes there (from `target`) and says which workspace that is.
    public mutating func go(to i: Int) -> String { at = i; return visits[i] }
}

/// A project's own screen: its oldest desk, the one its chats are on. It has no heading and doesn't close; every other
/// workspace is a group.
public func mainWorkspace(of r: Repo, among ws: [Worktree]) -> Worktree? {
    ws.filter { $0.repoId == r.id && $0.path == r.path && !$0.archived }.min { $0.createdAt < $1.createdAt }
}

/// An agent nobody has asked anything yet.
public func isUnstarted(_ s: Session) -> Bool { s.agent != "shell" && s.status == .idle && s.title.isEmpty }

/// New Group: one nobody has started is already there, its name still the placeholder. Nil: make one.
public func unstartedGroup(of r: Repo, rows: [Worktree], sessions: [Session]) -> Worktree? {
    rows.first { w in
        w.isUnnamed && w.id != mainWorkspace(of: r, among: rows)?.id
            && sessions.allSatisfy { $0.worktreeId != w.id || $0.status == .exited || isUnstarted($0) }
    }
}

/// Several workspaces closed at once (the sidebar's multi-selection): a project's own screen stays (without one, the oldest
/// picked, when every open one was), a desk in the project's folder is removed, a workspace on its own branch is archived.
public struct WorkspaceClosing: Equatable, Sendable {
    public private(set) var remove: [String] = [], archive: [String] = []
    /// Some picked workspaces stay, so their project keeps one.
    public private(set) var keptSome = false
    public var ids: [String] { remove + archive }

    /// `open`: every workspace not archived; `repos` say where each project's folder is.
    public init(picked: [Worktree], open: [Worktree], repos: [Repo]) {
        var kept = Set<String>()
        for (repo, mine) in Dictionary(grouping: picked, by: \.repoId) {
            if let r = repos.first(where: { $0.id == repo }), let own = mainWorkspace(of: r, among: open) {
                if mine.contains(own) { kept.insert(own.id) }
            } else if mine.count >= open.filter({ $0.repoId == repo }).count, let oldest = mine.min(by: { $0.createdAt < $1.createdAt }) {
                kept.insert(oldest.id)
            }
        }
        keptSome = !kept.isEmpty
        for w in picked where !kept.contains(w.id) {
            if w.path == repos.first(where: { $0.id == w.repoId })?.path { remove.append(w.id) } else { archive.append(w.id) }
        }
    }

    /// `w`'s last tab closed and nothing runs there: its row goes with it, and this is the row to show instead, the one
    /// under it or else the one over it. Nil: it stays, being on a branch of its own or the project's own screen.
    /// `rows`: the project's open workspaces, as the sidebar lists them.
    public static func afterLastTab(of w: Worktree, rows: [Worktree], repos: [Repo]) -> Worktree? {
        guard let r = repos.first(where: { $0.id == w.repoId }), w.path == r.path, w.id != mainWorkspace(of: r, among: rows)?.id,
              let i = rows.firstIndex(where: { $0.id == w.id }) else { return nil }
        return rows.dropFirst(i + 1).first ?? rows[..<i].last
    }
}
