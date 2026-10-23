import Foundation
import Core

/// What the sidebar lists, decided without a window: projects → workspaces → agents, narrowed by a filter and a search,
/// with what needs you and what you pinned lifted above the projects.
/// The raw values are the menu's English titles (and what UserDefaults keeps).
public enum SidebarFilter: String, Sendable, CaseIterable {
    case all = "All Workspaces", working = "Working", needsYou = "Needs You", withPR = "With a Pull Request"
}

public struct SidebarItem: Equatable, Sendable {
    /// `section`: "Needs You" / "Pinned"; `needs`: an agent listed in the first of them (it's also under its workspace).
    public enum Kind: Equatable, Sendable { case project(String), workspace(String), agent(String), section(String), needs(String) }
    public var kind: Kind
    public var children: [SidebarItem] = []
}

public struct SidebarTree {
    public var projects: [Repo]
    /// Every workspace in display order (archived ones are skipped here).
    public var workspaces: [Worktree]
    public var sessions: [Session]
    /// Sessions waiting on you, most urgent first (already ordered; see `AttentionQueue`).
    public var attention: [Session]
    public var pinned: [String] = []
    public var query = ""
    public var filter = SidebarFilter.all
    /// The workspace on screen never vanishes from the list.
    public var current: String?
    public var statusLabel: (AgentStatus) -> String = { $0.rawValue }
    public var hasPR: (Worktree) -> Bool = { _ in false }
    /// Puts "Needs You" rows in a stable order (see `StableOrder`).
    public var stableOrder: ([String]) -> [String] = { $0 }
    /// An agent joins "Needs You" once it has needed you this long (since its `statusAt`): one that asks or stops and goes
    /// on by itself a moment later doesn't land on top of the projects and leave again, moving them twice.
    public var settle: TimeInterval = 0
    public var now = Date()
    /// When the next agent held back by `settle` joins: the list wants building again then.
    public var settlesAt: Date? { attention.map { ($0.statusAt ?? $0.createdAt) + settle }.filter { $0 > now }.min() }

    public init(projects: [Repo], workspaces: [Worktree], sessions: [Session], attention: [Session]) {
        self.projects = projects; self.workspaces = workspaces; self.sessions = sessions; self.attention = attention
    }

    public func build() -> [SidebarItem] {
        let q = query.lowercased()
        let narrowed = !q.isEmpty || filter != .all
        func hit(_ text: String...) -> Bool { q.isEmpty || text.contains { $0.lowercased().contains(q) } }
        func passes(_ w: Worktree, _ agents: [Session]) -> Bool {
            if w.id == current { return true }
            switch filter {
            case .all: return true
            case .working: return agents.contains { $0.status == .working }
            case .needsYou: return agents.contains { [.waiting, .error].contains($0.status) || ($0.status == .done && $0.unread) }
            case .withPR: return hasPR(w)
            }
        }
        func workspace(_ w: Worktree, _ r: Repo) -> SidebarItem? {
            // Agents only: terminals are tabs, not something to keep an eye on.
            let agents = sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }
            guard passes(w, agents) else { return nil }
            let whole = hit(w.displayName, w.branch, r.name)
            let kept = whole ? agents : agents.filter { hit($0.title, $0.agent ?? "", $0.summary, statusLabel($0.status)) }   // "needs", "working", "done" act as filters
            guard whole || !kept.isEmpty else { return nil }
            return SidebarItem(kind: .workspace(w.id), children: kept.map { SidebarItem(kind: .agent($0.id)) })
        }
        let live = workspaces.filter { !$0.archived }
        var out: [SidebarItem] = []
        let needs = attention.filter { s in
            live.contains { $0.id == s.worktreeId } && hit(s.title, s.agent ?? "", s.summary) && (s.statusAt ?? s.createdAt) + settle <= now
        }
        if !needs.isEmpty, filter == .all || filter == .needsYou, live.count > 2 {
            out.append(SidebarItem(kind: .section("Needs You"), children: stableOrder(needs.map(\.id)).map { SidebarItem(kind: .needs($0)) }))
        }
        let pinnedItems = pinned.compactMap { id in
            workspaces.first { $0.id == id }.flatMap { w in projects.first { $0.id == w.repoId }.flatMap { workspace(w, $0) } }
        }
        if !pinnedItems.isEmpty { out.append(SidebarItem(kind: .section("Pinned"), children: pinnedItems)) }
        out += projects.compactMap { r in
            let kids = live.filter { $0.repoId == r.id && !pinned.contains($0.id) }.compactMap { workspace($0, r) }
            return kids.isEmpty && narrowed ? nil : SidebarItem(kind: .project(r.id), children: kids)
        }
        return out
    }
}

/// Rows don't jump under the pointer: what needs you keeps its place, new ones join at the end, and the list is put
/// back in the queue's order only every `interval` seconds.
public struct StableOrder: Sendable {
    private var order: [String] = []
    private var sortedAt = Date.distantPast
    public var interval: TimeInterval = 180
    public init() {}

    public mutating func callAsFunction(_ fresh: [String], now: Date = Date()) -> [String] {
        if now.timeIntervalSince(sortedAt) > interval { order = fresh; sortedAt = now; return fresh }
        order = order.filter(fresh.contains) + fresh.filter { !order.contains($0) }
        return order
    }
}
