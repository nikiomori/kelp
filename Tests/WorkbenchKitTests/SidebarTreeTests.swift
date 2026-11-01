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
    #expect(kinds(out[0].children) == [.agent("a1"), .workspace("w2")])   // archived workspaces aren't listed
    #expect(out[0].children[0].workspace == "w1")   // an ended agent and a plain terminal don't make it a group
}

/// A new chat never regroups the ones already there: the heading came with their second agent.
@Test func aHeadingDoesntWaitForASecondScreen() {
    let ss = [agent("a1", in: "w1", .working), agent("a2", in: "w1", .idle)]
    let one = tree([wt("w1", "r1", "a")], ss).build()
    #expect(kinds(one[0].children) == [.workspace("w1")] && one[0].workspace == nil)
    let two = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b")], ss).build()
    #expect(kinds(two[0].children) == [.workspace("w1"), .workspace("w2")])
}

@Test func aHeadingShowsOnlyWhenAScreenHoldsTwoAgents() {
    let alone = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b")], [agent("a1", in: "w1", .working)]).build()
    #expect(kinds(alone[0].children) == [.agent("a1"), .workspace("w2")])
    #expect(alone[0].children[0].workspace == "w1" && alone[0].children[0].children.isEmpty)
    let two = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b")], [agent("a1", in: "w1", .working), agent("a2", in: "w1", .idle)]).build()
    #expect(kinds(two[0].children) == [.workspace("w1"), .workspace("w2")])
    #expect(kinds(two[0].children[0].children) == [.agent("a1"), .agent("a2")])
    #expect(two[0].children[0].children[0].workspace == nil)   // under a heading a row is only itself
}

@Test func agentsFirstLiftsProjectsWithAgentsAndKeepsTheRestInOrder() {
    let r3 = Repo(id: "r3", name: "gamma", path: "/c")
    var t = SidebarTree(projects: [r1, r2, r3], workspaces: [wt("w1", "r1", "main"), wt("w2", "r2", "main"), wt("w3", "r3", "main")],
                        sessions: [agent("a3", in: "w3", .working)])
    #expect(kinds(t.build()) == [.project("r1"), .project("r2"), .project("r3")])   // as arranged, by default
    t.activeFirst = true
    #expect(kinds(t.build()) == [.project("r3"), .project("r1"), .project("r2")])
}

@Test func aProjectWithOneWorkspaceStandsForIt() {
    let out = tree([wt("w1", "r1", "main"), wt("w2", "r1", "old", archived: true)], [agent("a1", in: "w1", .working)]).build()
    #expect(out[0].workspace == "w1" && kinds(out[0].children) == [.agent("a1")])   // the agents right under the project
    #expect(out[1].workspace == nil && out[1].children.isEmpty)   // no workspace at all
}

@Test func searchKeepsWhatMatchesAndDropsEmptyProjects() {
    var t = tree([wt("w1", "r1", "login"), wt("w2", "r1", "billing"), wt("w9", "r1", "spare")], [agent("a1", in: "w2", .working, title: "fix invoices")])
    t.query = "inv"
    var out = t.build()
    #expect(kinds(out) == [.project("r1")])
    #expect(kinds(out[0].children) == [.agent("a1")])   // the agent's title matched, not the workspace's
    #expect(out[0].children[0].workspace == "w2")
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
    #expect(kinds(t.build().flatMap(\.children)) == [.agent("a1")])
}

@Test func filtersNarrowAndTheCurrentWorkspaceStays() {
    let ws = [wt("w1", "r1", "a"), wt("w2", "r1", "b"), wt("w3", "r2", "c"), wt("w4", "r2", "d")]
    let ss = [agent("a1", in: "w1", .working), agent("a2", in: "w2", .waiting), agent("a3", in: "w3", .done, unread: true)]
    var t = tree(ws, ss)
    t.filter = .working
    #expect(kinds(t.build().flatMap(\.children)) == [.agent("a1")])
    t.filter = .needsYou
    #expect(kinds(t.build().flatMap(\.children)) == [.agent("a2"), .agent("a3")])   // waiting, and done but unread
    t.current = "w1"
    #expect(kinds(t.build().flatMap(\.children)) == [.agent("a1"), .agent("a2"), .agent("a3")])
    t.current = nil; t.filter = .withPR; t.hasPR = { $0.id == "w3" }
    #expect(kinds(t.build().flatMap(\.children)) == [.agent("a3")])
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
