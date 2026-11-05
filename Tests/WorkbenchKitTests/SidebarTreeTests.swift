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

/// No Project (chats outside any project) stays the last row, whatever order the rest are in.
@Test func thePinnedProjectStaysLast() {
    let r3 = Repo(id: "r3", name: "gamma", path: "/c")
    var t = SidebarTree(projects: [r1, r2, r3], workspaces: [wt("w1", "r1", "main"), wt("w2", "r2", "main"), wt("w3", "r3", "main")],
                        sessions: [agent("a3", in: "w3", .working)])
    t.pinnedLast = "r3"
    #expect(kinds(t.build()) == [.project("r1"), .project("r2"), .project("r3")])
    t.activeFirst = true   // r3 has the agent, yet stays last
    #expect(kinds(t.build()) == [.project("r1"), .project("r2"), .project("r3")])
    t.pinnedLast = "r1"
    #expect(kinds(t.build()) == [.project("r3"), .project("r2"), .project("r1")])
}

private func workspace(_ id: String, _ r: Repo, at t: TimeInterval = 0) -> Worktree {
    Worktree(id: id, repoId: r.id, branch: "main", path: r.path, createdAt: Date(timeIntervalSince1970: t))
}

/// A project's own screen has no heading: its agents are the project's chats, right under the name. Nothing else moves
/// when a group comes: it goes under them, under a heading of its own, however many agents it holds.
@Test func aProjectsChatsHaveNoHeadingAndGroupsAlwaysDo() {
    let chats = [agent("a1", in: "d", .working), agent("a2", in: "d", .idle)]
    let alone = tree([workspace("d", r1)], chats).build()
    #expect(alone[0].workspace == "d" && kinds(alone[0].children) == [.agent("a1"), .agent("a2")])
    #expect(alone[1].workspace == nil && alone[1].children.isEmpty)   // no workspace at all
    let grouped = tree([workspace("d", r1), workspace("g", r1, at: 1), workspace("e", r1, at: 2)], chats + [agent("a3", in: "g", .working)]).build()
    #expect(grouped[0].workspace == "d")
    #expect(kinds(grouped[0].children) == [.agent("a1"), .agent("a2"), .workspace("g"), .workspace("e")])
    #expect(kinds(grouped[0].children[2].children) == [.agent("a3")])   // one agent keeps its heading, and none does too
}

/// Which workspace is the project's own doesn't follow a dragged order, and a checkout elsewhere is never it.
@Test func aProjectsOwnScreenIsItsOldestWorkspace() {
    let older = workspace("old", r1, at: 1), newer = workspace("new", r1, at: 2), branch = wt("b", "r1", "feat")
    #expect(mainWorkspace(of: r1, among: [branch, newer, older]) == older)
    #expect(mainWorkspace(of: r1, among: [branch]) == nil)
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

/// Projects on hosts come after this Mac's, each host's together under its header where its first project stood; a
/// folded host is its header alone. This Mac's have none.
@Test func remoteProjectsComeAfterThisMacsUnderTheirHost() {
    let r3 = Repo(id: "r3", name: "gamma", path: "/c"), r4 = Repo(id: "r4", name: "delta", path: "/d")
    var t = SidebarTree(projects: [r3, r1, r4, r2], workspaces: [], sessions: [])
    #expect(kinds(t.build()) == [.project("r3"), .project("r1"), .project("r4"), .project("r2")])
    t.hosts = ["r3": "box", "r4": "pi", "r2": "box"]
    #expect(kinds(t.build()) == [.project("r1"), .host("box"), .project("r3"), .project("r2"), .host("pi"), .project("r4")])
    t.folded = ["box"]
    #expect(kinds(t.build()) == [.project("r1"), .host("box"), .host("pi"), .project("r4")])
}

/// A parked agent leaves its project for the "Parked" heading, which sits over the pinned row; none parked, no heading.
@Test func parkedAgentsSitUnderTheirHeadingOverThePinnedRow() {
    var t = tree([wt("w1", "r1", "main"), wt("w2", "r2", "main")], [agent("a1", in: "w1", .working), agent("a2", in: "w1", .done)])
    t.pinnedLast = "r2"
    #expect(!kinds(t.build()).contains(.parked))
    t.parked = ["a2"]
    let out = t.build()
    #expect(kinds(out) == [.project("r1"), .parked, .project("r2")])
    #expect(kinds(out[0].children.flatMap(\.children)) == [.agent("a1")])
    #expect(kinds(out[1].children) == [.agent("a2")])
}
