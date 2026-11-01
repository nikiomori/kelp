import Foundation
import Core

/// What the sidebar lists, decided without a window: projects → their chats, then their groups → the chats in those,
/// narrowed by a filter and a search, with what you pinned lifted above the projects. A project's chats are the agents on
/// its own screen (`mainWorkspace`), with no heading; every other workspace is a group someone made, always with its
/// heading. An agent's children stand on its row, not on rows of their own. What needs you is in the line over the list
/// (`Inbox`).
/// The raw values are the menu's English titles (and what UserDefaults keeps).
public enum SidebarFilter: String, Sendable, CaseIterable {
    case all = "All Chats", working = "Working", needsYou = "Needs You", withPR = "With a Pull Request"
}

public struct SidebarItem: Equatable, Sendable {
    /// `section`: "Pinned".
    public enum Kind: Equatable, Sendable { case project(String), workspace(String), agent(String), section(String) }
    public var kind: Kind
    public var children: [SidebarItem] = []
    /// On a project: its own screen, which its row stands for, with that screen's agents right under the name.
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
                return agents.contains {   // a child's result is its parent's to read
                    [.waiting, .error].contains($0.status) || ($0.parent == nil && [.done, .hibernated].contains($0.status) && $0.unread)
                }
            case .withPR: return hasPR(w)
            }
        }
        func workspace(_ w: Worktree, _ r: Repo) -> SidebarItem? {
            // Agents only: terminals are tabs, not something to keep an eye on.
            let agents = sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }
            guard passes(w, agents) else { return nil }
            let whole = hit(w.displayName, w.branch, r.name)
            // "needs", "working", "done" act as filters; a child is found on its parent's row. One on another screen keeps a
            // row there: it's what that screen holds.
            func found(_ s: Session) -> Bool { hit(s.title, s.agent ?? "", s.summary, statusLabel(s.status)) }
            let rows = agents.filter { a in !agents.contains { $0.id == a.parent } }
            let kept = whole ? rows : rows.filter { a in found(a) || agents.children(of: a.id).contains(where: found) }
            guard whole || !kept.isEmpty else { return nil }
            return SidebarItem(kind: .workspace(w.id), children: kept.map { SidebarItem(kind: .agent($0.id)) })
        }
        let live = workspaces.filter { !$0.archived }
        var out: [SidebarItem] = []
        let pinnedItems = pinned.compactMap { id in
            workspaces.first { $0.id == id }.flatMap { w in projects.first { $0.id == w.repoId }.flatMap { workspace(w, $0) } }
        }
        if !pinnedItems.isEmpty { out.append(SidebarItem(kind: .section("Pinned"), children: pinnedItems)) }
        let listed = projects.compactMap { r -> SidebarItem? in
            let own = mainWorkspace(of: r, among: live).flatMap { pinned.contains($0.id) ? nil : $0 }
            let chats = own.flatMap { workspace($0, r) }?.children ?? []
            let groups = live.filter { w in w.repoId == r.id && w.id != mainWorkspace(of: r, among: live)?.id && !pinned.contains(w.id) }
                .compactMap { workspace($0, r) }
            if chats.isEmpty && groups.isEmpty && narrowed { return nil }
            return SidebarItem(kind: .project(r.id), children: chats + groups, workspace: own?.id)
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
