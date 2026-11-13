import Core
import Foundation
import TestSupport
import Testing

@testable import KelpKit

@MainActor private func agent(_ id: String, in wid: String, parent: String? = nil) -> Session {
    var s = Session(id: id, worktreeId: wid, cwd: "/", command: "claude", agent: "claude", status: .working)
    s.parent = parent
    return s
}

/// An agent's children come from an index made once per change of the sessions: it follows each one (a child added,
/// moved to another parent, ended, removed).
@MainActor @Test func anAgentsChildrenFollowTheSessions() {
    let m = AppModel()
    m.sessions = [agent("p", in: "w"), agent("q", in: "w"), agent("k", in: "w", parent: "p")]
    #expect(m.children(of: "p").map(\.id) == ["k"])
    m.upsert(agent("g", in: "w", parent: "k"))   // a grandchild
    #expect(m.children(of: "p").map(\.id) == ["k", "g"])
    m.handle(agent("k", in: "w", parent: "q"))   // moved: the event's copy replaces the one here
    #expect(m.children(of: "p").isEmpty && m.children(of: "q").map(\.id) == ["k", "g"])
    m.removed(session: "g")
    #expect(m.children(of: "q").map(\.id) == ["k"])
    var ended = agent("k", in: "w", parent: "q")
    ended.status = .exited
    m.upsert(ended)
    #expect(m.children(of: "q").isEmpty)
}

/// A session, workspace and project are found by id through indexes that follow every change: added, replaced in place,
/// removed.
@MainActor @Test func lookupsByIdFollowTheLists() {
    let m = AppModel()
    m.sessions = [agent("a", in: "w1"), agent("b", in: "w1")]
    #expect(m.session("b")?.worktreeId == "w1")
    m.upsert(agent("b", in: "w2"))   // replaced where it was
    #expect(m.session("b")?.worktreeId == "w2" && m.session("a")?.worktreeId == "w1")
    m.handle(RemovedEvent(session: "a"))
    #expect(m.session("a") == nil && m.session("b")?.worktreeId == "w2")
    m.upsert(agent("c", in: "w3"))
    #expect(m.session("c")?.worktreeId == "w3" && m.session("b") != nil)

    m.handle(Repo(id: "r1", name: "one", path: "/one"))
    m.handle(Worktree(id: "w1", repoId: "r1", branch: "main", path: "/one"))
    #expect(m.repo("r1")?.name == "one" && m.worktree("w1")?.branch == "main")
    m.handle(Worktree(id: "w1", repoId: "r1", branch: "dev", path: "/one"))
    #expect(m.worktree("w1")?.branch == "dev")
    m.handle(RemovedEvent(worktree: "w1"))
    #expect(m.worktree("w1") == nil && m.worktree(nil) == nil)
    m.handle(RemovedEvent(repo: "r1"))
    #expect(m.repo("r1") == nil)
}

/// The sidebar's order lets go of what the daemon says was removed, and only then: a list that isn't read yet doesn't
/// empty it.
@MainActor @Test func theSidebarOrderForgetsRemovedRows() {
    let m = AppModel()
    m.repos = [Repo(id: "r1", name: "b", path: "/b"), Repo(id: "r2", name: "a", path: "/a")]
    m.worktrees = [Worktree(id: "w1", repoId: "r1", branch: "main", path: "/b")]
    m.reorder(["r1", "r2"])
    m.reorder(["w1"])
    #expect(m.projects.map(\.id) == ["r1", "r2"])
    m.repos = []   // not loaded (yet): the order stays
    #expect(m.arrangement.order == ["w1", "r1", "r2"])
    m.handle(RemovedEvent(repo: "r1"))   // its workspaces go with it
    #expect(m.arrangement.order == ["r2"])
    m.repos = [Repo(id: "r3", name: "0", path: "/0"), Repo(id: "r2", name: "a", path: "/a")]
    #expect(m.projects.map(\.id) == ["r2", "r3"])   // the rank follows the order's change
}

/// A connection hears each watch once: on the first one the refresh and the views have told it already, and a second
/// `watch.start` would make the daemon read it again (CI: often, for 45 s). A new connection hears all of it.
@MainActor @Test func aConnectionIsToldEachWatchOnce() async throws {
    let rig = try await AppRig(files: [:])
    defer { rig.done() }
    let m = rig.app
    m.watch(.ci, rig.workspace.id)   // a view on screen, as the refresh's context watches: sent as it's asked for
    await m.refresh()
    #expect(m.tellWatches(rig.client).isEmpty, "the same connection told again")
    let next = try RPCClient(socket: rig.root.appendingPathComponent("kelp.sock").path)
    defer { next.close() }
    m.daemon.use(next)
    #expect(Set(m.tellWatches(next)) == Set(m.watching.keys))
    #expect(m.tellWatches(next).isEmpty)
}

/// The context ring is on an agent's tab, and tabs are the workspace on screen's: only its agents' context is watched.
/// One read before stays for when its workspace shows again; an agent that ended lets go of it.
@MainActor @Test func onlyTheShownWorkspacesAgentsHaveTheirContextWatched() {
    let m = AppModel()
    var shell = Session(id: "t", worktreeId: "w1", cwd: "/", command: "zsh", agent: "shell")
    shell.status = .idle
    m.sessions = [agent("a", in: "w1"), agent("b", in: "w2"), shell]
    func watched() -> Set<String> { Set(m.watching.keys.filter { $0.topic == .context }.map(\.key)) }
    m.workbench.workspaceId = "w1"
    #expect(watched() == ["a"])
    m.workbench.workspaceId = "w2"
    #expect(watched() == ["b"])
    var ended = agent("b", in: "w2")
    ended.status = .exited
    m.handle(ended)
    #expect(watched().isEmpty)
}

/// A parked agent comes back when the newest run of any workflow failed, as the daemon and the marks read CI: not only
/// when the newest run of them all did.
@MainActor @Test func aParkedAgentComesBackWhenAnyWorkflowsLatestRunFailed() {
    let m = AppModel()
    m.upsert(agent("a", in: "w1"))
    m.arrangement.park("a", until: Mutes.forever)
    func run(_ id: Int, _ workflow: String, _ conclusion: String) -> CIRuns.Run {
        CIRuns.Run(
            id: id, title: "", workflow: workflow, status: "completed", conclusion: conclusion, event: "push", url: "",
            createdAt: "")
    }
    // Newest first: Lint passed just now, and CI's newest run failed.
    let runs = [run(3, "Lint", "success"), run(2, "CI", "failure"), run(1, "Lint", "failure")]
    m.land(CIEvent(worktree: "w1", result: CIRunsList.Result(branch: "main", runs: runs, workflows: [])))
    #expect(!m.arrangement.isParked("a") && m.arrangement.parkedBack["a"] == "CI failed")
}

/// Session news that comes together is applied together, and never after an event sent behind it.
@MainActor @Test func sessionNewsIsAppliedTogetherInOrder() async throws {
    let m = AppModel(builtins: [])
    m.arrived(agent("a", in: "w1"))
    m.arrived(agent("b", in: "w1"))
    #expect(m.session("a") == nil && m.held.count == 2)   // held for the turn
    m.arrived(RemovedEvent(session: "a"))   // another kind: what's held lands first, then it
    #expect(m.session("a") == nil && m.session("b") != nil && m.held.isEmpty)
    m.arrived(agent("c", in: "w1"))
    #expect(try await waitFor(2) { m.session("c") != nil })
}

/// Kelp's window not seen: what only it shows isn't read (ports here), what notifications and the Dock follow is (CI),
/// and both are told again once it's seen.
@MainActor @Test func whatOnlyTheWindowShowsWaitsWhileItIsntSeen() async throws {
    let rig = try await AppRig(files: [:])
    defer { rig.done() }
    let m = rig.app
    let ports = WatchStart(.ports, rig.workspace.id), ci = WatchStart(.ci, rig.workspace.id)
    m.watch(.ports, rig.workspace.id)
    m.watch(.ci, rig.workspace.id)
    await m.refresh()
    m.setAway(true)
    #expect(!m.told.contains(ports) && m.told.contains(ci))
    #expect(!m.tellWatches(rig.client).contains(ports))   // a reconnect meanwhile doesn't start it either
    m.watch(.ports, "other")
    #expect(!m.told.contains(WatchStart(.ports, "other")))
    m.setAway(false)
    #expect(m.told.contains(ports) && m.told.contains(WatchStart(.ports, "other")))
}
