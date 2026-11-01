import Foundation
import Core

/// What the sidebar lists, decided without a window: projects → workspaces → agents, narrowed by a filter and a search,
/// with what you pinned lifted above the projects; a workspace with one agent is that agent's row, a heading shows when a
/// screen holds two and only then, however many screens its project has. What needs you is in the line over the list (`Inbox`).
/// The raw values are the menu's English titles (and what UserDefaults keeps).
public enum SidebarFilter: String, Sendable, CaseIterable {
    case all = "All Chats", working = "Working", needsYou = "Needs You", withPR = "With a Pull Request"
}

public struct SidebarItem: Equatable, Sendable {
    /// `section`: "Pinned".
    public enum Kind: Equatable, Sendable { case project(String), workspace(String), agent(String), section(String) }
    public var kind: Kind
    public var children: [SidebarItem] = []
    /// What this row stands for: on a project with one workspace that workspace, its agents right under the name; on an
    /// agent alone in its workspace that workspace, with no heading over the row.
    public var workspace: String?
}

public struct SidebarTree {
    public var projects: [Repo]
    /// Every workspace in display order (archived ones are skipped here).
    public var workspaces: [Worktree]
    public var sessions: [Session]
    public var pinned: [String] = []
    public var query = ""
    public var filter = SidebarFilter.all
    /// The workspace on screen never vanishes from the list.
    public var current: String?
    public var statusLabel: (AgentStatus) -> String = { $0.rawValue }
    public var hasPR: (Worktree) -> Bool = { _ in false }
    /// Projects with live agents first, each part in the order people gave them (Settings › Project order).
    public var activeFirst = false

    public init(projects: [Repo], workspaces: [Worktree], sessions: [Session]) {
        self.projects = projects; self.workspaces = workspaces; self.sessions = sessions
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
            case .needsYou:
                return agents.contains { [.waiting, .error].contains($0.status) || ([.done, .hibernated].contains($0.status) && $0.unread) }
            case .withPR: return hasPR(w)
            }
        }
        func workspace(_ w: Worktree, _ r: Repo) -> SidebarItem? {
            // Agents only: terminals are tabs, not something to keep an eye on.
            let agents = sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }
            guard passes(w, agents) else { return nil }
            let whole = hit(w.displayName, w.branch, r.name)
            // "needs", "working", "done" act as filters
            let kept = whole ? agents : agents.filter { hit($0.title, $0.agent ?? "", $0.summary, statusLabel($0.status)) }
            guard whole || !kept.isEmpty else { return nil }
            return SidebarItem(kind: .workspace(w.id), children: kept.map { SidebarItem(kind: .agent($0.id)) })
        }
        func row(_ i: SidebarItem) -> SidebarItem {
            guard i.children.count == 1, case .workspace(let id) = i.kind else { return i }
            return SidebarItem(kind: i.children[0].kind, workspace: id)
        }
        let live = workspaces.filter { !$0.archived }
        var out: [SidebarItem] = []
        let pinnedItems = pinned.compactMap { id in
            workspaces.first { $0.id == id }.flatMap { w in projects.first { $0.id == w.repoId }.flatMap { workspace(w, $0).map(row) } }
        }
        if !pinnedItems.isEmpty { out.append(SidebarItem(kind: .section("Pinned"), children: pinnedItems)) }
        let listed = projects.compactMap { r -> SidebarItem? in
            let mine = live.filter { $0.repoId == r.id && !pinned.contains($0.id) }
            let kids = mine.compactMap { workspace($0, r) }
            if kids.isEmpty && narrowed { return nil }
            if mine.count == 1, let only = kids.first, only.children.count < 2 {
                return SidebarItem(kind: .project(r.id), children: only.children, workspace: mine[0].id)
            }
            return SidebarItem(kind: .project(r.id), children: kids.map(row))
        }
        func busy(_ i: SidebarItem) -> Bool { i.children.contains { if case .agent = $0.kind { true } else { busy($0) } } }
        out += activeFirst ? listed.filter(busy) + listed.filter { !busy($0) } : listed
        return out
    }
}

/// The agents the line over the list shows, most urgent first: not the one on screen (you see it already), and only once
/// it has needed you `settle` seconds (since its `statusAt`), so one that asks or stops and goes on by itself a moment
/// later never shows up at all.
public struct Inbox: Sendable {
    /// Sessions waiting on you, in the order to visit them (see `AttentionQueue`).
    public var queue: [Session]
    public var viewing: Set<String> = []
    public var settle: TimeInterval = 5
    public var now = Date()
    public init(queue: [Session]) { self.queue = queue }

    public var shown: [Session] { queue.filter { !viewing.contains($0.id) && since($0) + settle <= now } }
    /// When the next one held back by `settle` is due: look again then.
    public var settlesAt: Date? { queue.filter { !viewing.contains($0.id) }.map { since($0) + settle }.filter { $0 > now }.min() }
    private func since(_ s: Session) -> Date { s.statusAt ?? s.createdAt }
}
