import Foundation
import Testing
import Core
import WorkbenchKit

private let r1 = Repo(id: "r1", name: "alpha", path: "/a"), r2 = Repo(id: "r2", name: "beta", path: "/b")
private func wt(_ id: String, _ repo: String, _ branch: String, archived: Bool = false) -> Worktree {
    Worktree(id: id, repoId: repo, branch: branch, path: "/\(id)", archived: archived)
}
private func agent(_ id: String, in w: String, _ status: AgentStatus, title: String = "", unread: Bool = false, agent: String = "claude") -> Session {
    var s = Session(id: id, worktreeId: w, cwd: "/", command: agent, agent: agent, status: status, title: title)
    s.unread = unread
    return s
}
private func tree(_ ws: [Worktree], _ ss: [Session] = []) -> SidebarTree {
    SidebarTree(projects: [r1, r2], workspaces: ws, sessions: ss)
}
private func kinds(_ items: [SidebarItem]) -> [SidebarItem.Kind] { items.map(\.kind) }

@Test func projectsListTheirWorkspacesAndLiveAgentsOnly() {
    let ss = [agent("a1", in: "w1", .working), agent("a2", in: "w1", .exited), agent("sh", in: "w1", .idle, agent: "shell")]
    let out = tree([wt("w1", "r1", "main"), wt("w2", "r1", "old"), wt("w3", "r1", "gone", archived: true)], ss).build()
    #expect(kinds(out) == [.project("r1"), .project("r2")])
    #expect(kinds(out[0].children) == [.workspace("w1"), .workspace("w2")])   // archived workspaces aren't listed
    #expect(kinds(out[0].children[0].children) == [.agent("a1")])   // an ended agent and a plain terminal aren't
}

@Test func agentsFirstLiftsProjectsWithAgentsAndKeepsTheRestInOrder() {
    let r3 = Repo(id: "r3", name: "gamma", path: "/c")
    var t = SidebarTree(projects: [r1, r2, r3], workspaces: [wt("w1", "r1", "main"), wt("w2", "r2", "main"), wt("w3", "r3", "main")],
                        sessions: [agent("a3", in: "w3", .working)])
    #expect(kinds(t.build()) == [.project("r1"), .project("r2"), .project("r3")])   // as arranged, by default
    t.activeFirst = true
    #expect(kinds(t.build()) == [.project("r3"), .project("r1"), .project("r2")])
}

private func desk(_ id: String, _ r: Repo, at t: TimeInterval = 0) -> Worktree {
    Worktree(id: id, repoId: r.id, branch: "main", path: r.path, createdAt: Date(timeIntervalSince1970: t))
}

/// A project's own screen has no heading: its agents are the project's chats, right under the name. Nothing else moves
/// when a group comes: it goes under them, under a heading of its own, however many agents it holds.
@Test func aProjectsChatsHaveNoHeadingAndGroupsAlwaysDo() {
    let chats = [agent("a1", in: "d", .working), agent("a2", in: "d", .idle)]
    let alone = tree([desk("d", r1)], chats).build()
    #expect(alone[0].workspace == "d" && kinds(alone[0].children) == [.agent("a1"), .agent("a2")])
    #expect(alone[1].workspace == nil && alone[1].children.isEmpty)   // no workspace at all
    let grouped = tree([desk("d", r1), desk("g", r1, at: 1), desk("e", r1, at: 2)], chats + [agent("a3", in: "g", .working)]).build()
    #expect(grouped[0].workspace == "d")
    #expect(kinds(grouped[0].children) == [.agent("a1"), .agent("a2"), .workspace("g"), .workspace("e")])
    #expect(kinds(grouped[0].children[2].children) == [.agent("a3")])   // one agent keeps its heading, and none does too
}

/// Which desk is the project's own doesn't follow a dragged order, and a checkout elsewhere is never it.
@Test func aProjectsOwnScreenIsItsOldestDesk() {
    let older = desk("old", r1, at: 1), newer = desk("new", r1, at: 2), branch = wt("b", "r1", "feat")
    #expect(mainWorkspace(of: r1, among: [branch, newer, older]) == older)
    #expect(mainWorkspace(of: r1, among: [branch]) == nil)
}

@Test func searchKeepsWhatMatchesAndDropsEmptyProjects() {
    var t = tree([wt("w1", "r1", "login"), wt("w2", "r1", "billing"), wt("w9", "r1", "spare")], [agent("a1", in: "w2", .working, title: "fix invoices")])
    t.query = "inv"
    var out = t.build()
    #expect(kinds(out) == [.project("r1")])
    #expect(kinds(out[0].children) == [.workspace("w2")])   // the agent's title matched, not the workspace's
    #expect(kinds(out[0].children[0].children) == [.agent("a1")])
    t.query = "LOGIN"
    out = t.build()
    #expect(kinds(out[0].children) == [.workspace("w1")])   // case doesn't matter
    t.query = "nothing like this"
    #expect(t.build().isEmpty)
}

@Test func aWorkspaceNameMatchKeepsAllItsAgents() {
    var t = tree([wt("w1", "r1", "login")], [agent("a1", in: "w1", .working), agent("a2", in: "w1", .idle)])
    t.query = "login"
    #expect(t.build()[0].children[0].children.count == 2)
}

/// A paused agent's unread result is on the Needs You row: the filter finds it too.
@Test func theNeedsYouFilterFindsAPausedAgentsResult() {
    var t = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b")], [agent("a1", in: "w1", .hibernated, unread: true), agent("a2", in: "w2", .hibernated)])
    t.filter = .needsYou
    #expect(kinds(t.build().flatMap(\.children)) == [.workspace("w1")])
}

@Test func filtersNarrowAndTheCurrentWorkspaceStays() {
    let ws = [wt("w1", "r1", "a"), wt("w2", "r1", "b"), wt("w3", "r2", "c"), wt("w4", "r2", "d")]
    let ss = [agent("a1", in: "w1", .working), agent("a2", in: "w2", .waiting), agent("a3", in: "w3", .done, unread: true)]
    var t = tree(ws, ss)
    t.filter = .working
    #expect(kinds(t.build().flatMap(\.children)) == [.workspace("w1")])
    t.filter = .needsYou
    #expect(kinds(t.build().flatMap(\.children)) == [.workspace("w2"), .workspace("w3")])   // waiting, and done but unread
    t.current = "w1"
    #expect(kinds(t.build().flatMap(\.children)) == [.workspace("w1"), .workspace("w2"), .workspace("w3")])
    t.current = nil; t.filter = .withPR; t.hasPR = { $0.id == "w3" }
    #expect(kinds(t.build().flatMap(\.children)) == [.workspace("w3")])
}

@Test func pinnedWorkspacesMoveUpInsteadOfBeingCopied() {
    var t = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b"), wt("w3", "r1", "c")])
    t.pinned = ["w2", "gone"]   // an id that no longer exists is ignored
    let out = t.build()
    #expect(out[0].kind == .section("Pinned") && kinds(out[0].children) == [.workspace("w2")])
    #expect(kinds(out[1].children) == [.workspace("w1"), .workspace("w3")])
}

@Test func inboxSkipsTheAgentOnScreenAndWaitsUntilOneHasNeededYouAWhile() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var a = agent("a1", in: "w1", .done, unread: true); a.statusAt = t0
    var b = agent("b1", in: "w2", .waiting); b.statusAt = t0 - 60
    var inbox = Inbox(queue: [b, a])
    inbox.now = t0 + 2
    #expect(inbox.shown.map(\.id) == ["b1"])     // a1 is a blip so far: it may go on by itself
    #expect(inbox.settlesAt == t0 + 5)            // when to look again
    inbox.now = t0 + 5
    #expect(inbox.shown.map(\.id) == ["b1", "a1"])
    #expect(inbox.settlesAt == nil)
    inbox.viewing = ["b1"]
    #expect(inbox.shown.map(\.id) == ["a1"])     // you're looking at it already
}
