import Core
import Foundation

/// What the sidebar lists, decided without a window: projects with their chats, then their groups with the chats in
/// those. A project's chats are the agents on its own screen (`mainWorkspace`), with no heading. Every other workspace
/// is a group someone made, with a row of its own. An agent's children show on its row, not on rows of their own. What
/// needs you is in the line over the list (`Inbox`).
public struct SidebarItem: Equatable, Sendable {
    /// `host` is a server's header, with its projects after it on the same card. They aren't under it, because they
    /// keep their place in the outline. `parked` is the heading over agents put out of the way, which are its children.
    public enum Kind: Equatable, Sendable {
        case project(String), workspace(String), agent(String), host(String), parked
    }
    public var kind: Kind
    public var children: [SidebarItem] = []
    /// On a project, its own screen, which the project's row stands for, with that screen's agents right under the
    /// name.
    public var workspace: String?
    /// On a group, the chat that made it (`Worktree.madeBy`, a branch for its helpers), when the group stands right
    /// under that chat's row, a step further in, rather than among the project's groups.
    public var under: String?
}

public struct SidebarTree {
    public var projects: [Repo]
    /// Every workspace in display order (archived ones are skipped here).
    public var workspaces: [Worktree]
    public var sessions: [Session]
    /// Whether projects with live agents come first. Each part keeps the order people gave it (Settings › Project
    /// order).
    public var activeFirst = false
    /// The host each remote project is on, by project id. Remote projects come after this Mac's, each host's projects
    /// together under its header, where its first project stood.
    public var hosts: [String: String] = [:]
    /// Hosts whose projects are folded away, so only the header shows.
    public var folded: Set<String> = []
    /// The project that stays last whatever the order (No Project: chats outside any project).
    public var pinnedLast: String?
    /// Parked agents, which leave their projects and show under a "Parked" heading over the pinned row.
    public var parked: Set<String> = []

    public init(projects: [Repo], workspaces: [Worktree], sessions: [Session]) {
        self.projects = projects
        self.workspaces = workspaces
        self.sessions = sessions
    }

    public func build() -> [SidebarItem] {
        func workspace(_ worktree: Worktree) -> SidebarItem {
            // Only agents get rows, because terminals are tabs, not something to keep an eye on. An agent on another
            // screen keeps a row there, because it's what that screen holds.
            let agents = sessions.filter {
                $0.worktreeId == worktree.id && $0.status != .exited && !$0.isTerminal
                    && !parked.contains($0.id)
            }
            let rows = agents.filter { a in !agents.contains { $0.id == a.parent } }
            return SidebarItem(kind: .workspace(worktree.id), children: rows.map { SidebarItem(kind: .agent($0.id)) })
        }
        let live = workspaces.filter { !$0.archived }
        let listed = projects.map { r -> SidebarItem in
            let own = mainWorkspace(of: r, among: live)
            let chats = own.map(workspace)?.children ?? []
            // A group that an agent made stands under that agent's chat, but only for a chat on the project's own
            // screen. A group can't hold a group, so a group made from inside a group stays among the project's groups.
            let makers = Set(chats.compactMap { if case .agent(let id) = $0.kind { id } else { nil } })
            func maker(_ worktree: Worktree) -> String? {
                Self.maker(worktree).flatMap { makers.contains($0) ? $0 : nil }
            }
            let groups = live.filter { $0.repoId == r.id && $0.id != own?.id }
            let rows = chats.flatMap { chat -> [SidebarItem] in
                [chat]
                    + groups.filter { .agent(maker($0) ?? "") == chat.kind }.map {
                        var made = workspace($0)
                        made.under = maker($0)
                        return made
                    }
            }
            return SidebarItem(
                kind: .project(r.id), children: rows + groups.filter { maker($0) == nil }.map(workspace),
                workspace: own?.id)
        }
        func busy(_ sidebarItem: SidebarItem) -> Bool {
            sidebarItem.children.contains { if case .agent = $0.kind { true } else { busy($0) } }
        }
        let all = sections(activeFirst ? listed.filter(busy) + listed.filter { !busy($0) } : listed)
        func isPinned(_ sidebarItem: SidebarItem) -> Bool {
            pinnedLast != nil && sidebarItem.kind == .project(pinnedLast ?? "")
        }
        let away = sessions.filter { parked.contains($0.id) && $0.status != .exited }.map {
            SidebarItem(kind: .agent($0.id))
        }
        return all.filter { !isPinned($0) } + (away.isEmpty ? [] : [SidebarItem(kind: .parked, children: away)])
            + all.filter(isPinned)
    }

    /// The session that made a workspace: the agent itself, or the terminal an agent was typed into (`typed:<id>`).
    public static func maker(_ worktree: Worktree) -> String? {
        worktree.madeBy.map { $0.hasPrefix("typed:") ? String($0.dropFirst(6)) : $0 }
    }

    private func sections(_ listed: [SidebarItem]) -> [SidebarItem] {
        guard !hosts.isEmpty else { return listed }
        func host(_ sidebarItem: SidebarItem) -> String {
            if case .project(let id) = sidebarItem.kind { hosts[id] ?? "" } else { "" }
        }
        var order: [String] = []
        for h in [""] + listed.map(host) where !order.contains(h) { order.append(h) }
        return order.flatMap { h -> [SidebarItem] in
            let mine = listed.filter { host($0) == h }
            guard !h.isEmpty, !mine.isEmpty else { return mine }
            return [SidebarItem(kind: .host(h))] + (folded.contains(h) ? [] : mine)
        }
    }
}

/// The agents that the line over the list shows, most urgent first. The agent on screen is left out, because you see it
/// already. An agent shows only once it has needed you for `settle` seconds (since its `statusAt`), so one that asks or
/// stops and goes on by itself a moment later never shows up at all.
public struct Inbox: Sendable {
    /// Sessions waiting on you, in the order to visit them (see `AttentionQueue`).
    public var queue: [Session]
    public var viewing: Set<String> = []
    public var settle: TimeInterval = 5
    public var now = Date()
    public init(queue: [Session]) { self.queue = queue }

    public var shown: [Session] { queue.filter { !viewing.contains($0.id) && since($0) + settle <= now } }
    /// The agents the count says need you. This includes the agent on screen, as long as it asks (its row still says
    /// so).
    public var counted: [Session] { queue.filter { since($0) + settle <= now } }
    /// When the next agent held back by `settle` is due, which is when to look again.
    public var settlesAt: Date? {
        queue.filter { !viewing.contains($0.id) }.map { since($0) + settle }.filter { $0 > now }.min()
    }
    private func since(_ session: Session) -> Date { session.statusAt ?? session.createdAt }
}
