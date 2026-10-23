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
private func tree(_ ws: [Worktree], _ ss: [Session] = [], attention: [Session] = []) -> SidebarTree {
    SidebarTree(projects: [r1, r2], workspaces: ws, sessions: ss, attention: attention)
}
private func kinds(_ items: [SidebarItem]) -> [SidebarItem.Kind] { items.map(\.kind) }

@Test func projectsListTheirWorkspacesAndLiveAgentsOnly() {
    let ss = [agent("a1", in: "w1", .working), agent("a2", in: "w1", .exited), agent("sh", in: "w1", .idle, agent: "shell")]
    let out = tree([wt("w1", "r1", "main"), wt("w2", "r1", "old", archived: true)], ss).build()
    #expect(kinds(out) == [.project("r1"), .project("r2")])
    #expect(kinds(out[0].children) == [.workspace("w1")])   // archived workspaces aren't listed
    #expect(kinds(out[0].children[0].children) == [.agent("a1")])   // an ended agent and a plain terminal aren't
}

@Test func searchKeepsWhatMatchesAndDropsEmptyProjects() {
    var t = tree([wt("w1", "r1", "login"), wt("w2", "r1", "billing")], [agent("a1", in: "w2", .working, title: "fix invoices")])
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

@Test func filtersNarrowAndTheCurrentWorkspaceStays() {
    let ws = [wt("w1", "r1", "a"), wt("w2", "r1", "b"), wt("w3", "r2", "c")]
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
    var t = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b")])
    t.pinned = ["w2", "gone"]   // an id that no longer exists is ignored
    let out = t.build()
    #expect(out[0].kind == .section("Pinned") && kinds(out[0].children) == [.workspace("w2")])
    #expect(kinds(out[1].children) == [.workspace("w1")])
}

@Test func needsYouAppearsOnlyWithMoreThanAFewWorkspaces() {
    let ss = [agent("a1", in: "w1", .waiting)]
    var t = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b")], ss, attention: ss)
    #expect(kinds(t.build()) == [.project("r1"), .project("r2")])   // two workspaces: the list is short enough to see
    t = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b"), wt("w3", "r2", "c")], ss, attention: ss)
    let out = t.build()
    #expect(out[0].kind == .section("Needs You") && kinds(out[0].children) == [.needs("a1")])
    t.filter = .working
    #expect(!kinds(t.build()).contains(.section("Needs You")))
}

@Test func needsYouWaitsUntilAnAgentHasNeededYouAWhile() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var a = agent("a1", in: "w1", .done, unread: true); a.statusAt = t0
    var t = tree([wt("w1", "r1", "a"), wt("w2", "r1", "b"), wt("w3", "r2", "c")], [a], attention: [a])
    t.settle = 5; t.now = t0 + 2
    #expect(kinds(t.build()) == [.project("r1"), .project("r2")])   // a blip: it may go on by itself
    #expect(t.settlesAt == t0 + 5)                                   // when to look again
    t.now = t0 + 5
    #expect(t.build()[0].kind == .section("Needs You"))
    #expect(t.settlesAt == nil)
}

@Test func stableOrderKeepsRowsStillUntilItIsTimeToSort() {
    var order = StableOrder()
    let t0 = Date(timeIntervalSince1970: 1000)
    #expect(order(["a", "b"], now: t0) == ["a", "b"])
    #expect(order(["b", "c", "a"], now: t0 + 10) == ["a", "b", "c"])   // kept in place, the new one joins at the end
    #expect(order(["c"], now: t0 + 20) == ["c"])                         // one that stopped needing you leaves
    #expect(order(["b", "c", "a"], now: t0 + 500) == ["b", "c", "a"])    // after a few minutes: the queue's own order
}
