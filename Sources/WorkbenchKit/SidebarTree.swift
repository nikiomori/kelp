import Foundation
import Core

/// What the sidebar lists, decided without a window: projects → their chats, then their groups → the chats in those. A
/// project's chats are the agents on its own screen (`mainWorkspace`), with no heading; every other workspace is a group
/// someone made, a row of its own. An agent's children stand on its row, not on rows of their own. What needs you is in
/// the line over the list (`Inbox`).
public struct SidebarItem: Equatable, Sendable {
    /// `host`: a machine's heading, its projects after it (not under it: they keep their place in the outline); "" is this Mac.
    public enum Kind: Equatable, Sendable { case project(String), workspace(String), agent(String), host(String) }
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
    /// Projects with live agents first, each part in the order people gave them (Settings › Project order).
    public var activeFirst = false
    /// Project id → the host it's on, for remote projects. With any, the list is in sections, a heading a machine: this Mac
    /// first, then each host where its first project stands.
    public var hosts: [String: String] = [:]
    /// Hosts ("" this Mac) whose sections are folded: the heading alone.
    public var folded: Set<String> = []

    public init(projects: [Repo], workspaces: [Worktree], sessions: [Session]) {
        self.projects = projects; self.workspaces = workspaces; self.sessions = sessions
    }

    public func build() -> [SidebarItem] {
        func workspace(_ w: Worktree) -> SidebarItem {
            // Agents only: terminals are tabs, not something to keep an eye on. One on another screen keeps a row there:
            // it's what that screen holds.
            let agents = sessions.filter { $0.worktreeId == w.id && $0.status != .exited && $0.agent != "shell" }
            let rows = agents.filter { a in !agents.contains { $0.id == a.parent } }
            return SidebarItem(kind: .workspace(w.id), children: rows.map { SidebarItem(kind: .agent($0.id)) })
        }
        let live = workspaces.filter { !$0.archived }
        let listed = projects.map { r -> SidebarItem in
            let own = mainWorkspace(of: r, among: live)
            let groups = live.filter { $0.repoId == r.id && $0.id != own?.id }.map(workspace)
            return SidebarItem(kind: .project(r.id), children: (own.map(workspace)?.children ?? []) + groups, workspace: own?.id)
        }
        func busy(_ i: SidebarItem) -> Bool { i.children.contains { if case .agent = $0.kind { true } else { busy($0) } } }
        return sections(activeFirst ? listed.filter(busy) + listed.filter { !busy($0) } : listed)
    }

    private func sections(_ listed: [SidebarItem]) -> [SidebarItem] {
        guard !hosts.isEmpty else { return listed }
        func host(_ i: SidebarItem) -> String { if case .project(let id) = i.kind { hosts[id] ?? "" } else { "" } }
        var order: [String] = []
        for h in [""] + listed.map(host) where !order.contains(h) { order.append(h) }
        return order.flatMap { h -> [SidebarItem] in
            let mine = listed.filter { host($0) == h }
            return mine.isEmpty ? [] : [SidebarItem(kind: .host(h))] + (folded.contains(h) ? [] : mine)
        }
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
