import Agents
import Core
import Foundation
import GitKit
import Testing
import os

@testable import Daemon

/// A branch group whose removal fails (here: locked) keeps its turns' snapshots; removed, it lets them go from the
/// project's repository, its folder gone.
@Test func aFailedWorkspaceRemovalKeepsItsTurnRefs() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")])
    defer { w.d.stop() }
    let wt = try await workspace(w, "locked-turns")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    try #require(w.d.sessions.existing(s.id)).noteTurn(.working)
    #expect(try await waitFor(5) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty })
    let refs = { try Git.run(["for-each-ref", "refs/kelp/turns/"], cwd: w.repo.path, remotes: .none) }
    // The turn is listed before its snapshot's ref is written (git, off the turn's queue): waited for, not assumed
    #expect(try await waitFor(10) { try !refs().isEmpty })
    try Git.run(["worktree", "lock", wt.path], cwd: w.repo.path, remotes: .none)
    await expectRefusal(says: "is locked") { try await w.c.call(WorktreeRemove(id: wt.id)) }
    #expect(try !refs().isEmpty)
    try Git.run(["worktree", "unlock", wt.path], cwd: w.repo.path, remotes: .none)
    _ = try await w.c.call(WorktreeRemove(id: wt.id))
    #expect(try refs().isEmpty)
}

/// A removal that stopped after its folder went to the Trash, tried again: git's record of the worktree and its branch go
/// too, the branch only by the same rule (its commits elsewhere, or dropped on purpose).
@Test func removingAWorkspaceWhoseFolderIsGoneForgetsItInGit() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "half-gone")
    try FileManager.default.moveItem(atPath: wt.path, toPath: tmp().path + "/trashed")
    _ = try await w.c.call(WorktreeRemove(id: wt.id))
    #expect(
        try Git.linkedWorktrees(w.repo.path, remotes: .none).isEmpty
            && !Git.branchExists(w.repo.path, "half-gone", remotes: .none))
    // Its own commit: refused, the record stays, until told to drop it.
    let own = try await workspace(w, "own-commit")
    try Git.run(["commit", "-q", "--allow-empty", "-m", "only here"], cwd: own.path, remotes: .none)
    try FileManager.default.moveItem(atPath: own.path, toPath: tmp().path + "/trashed")
    await expectRefusal(says: "commit that aren't on any other branch") {
        try await w.c.call(WorktreeRemove(id: own.id))
    }
    #expect(try Git.branchExists(w.repo.path, "own-commit", remotes: .none) && w.d.store.worktree(own.id) != nil)
    _ = try await w.c.call(WorktreeRemove(id: own.id, dropCommits: true))
    #expect(
        try Git.linkedWorktrees(w.repo.path, remotes: .none).isEmpty
            && !Git.branchExists(w.repo.path, "own-commit", remotes: .none))
}

/// A new workspace in a remote project whose host is slow to answer: every other project's workspaces sync meanwhile.
@Test func aSlowHostDoesntHoldOtherProjectsWorkspaces() async throws {
    _ = localSSH
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let there = tmp().appendingPathComponent("slow-host").path
    try FileManager.default.createDirectory(atPath: there, withIntermediateDirectories: true)
    try Git.run(["init", "-q", "-b", "main"], cwd: there, remotes: .none)
    try Git.run(["commit", "-q", "--allow-empty", "-m", "a"], cwd: there, remotes: .none)
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    let shim = URL(fileURLWithPath: localSSH).deletingLastPathComponent()
    let flag = shim.appendingPathComponent("slow-host").path,
        asked = shim.appendingPathComponent("slow-host-asked").path
    try? FileManager.default.removeItem(atPath: asked)
    FileManager.default.createFile(atPath: flag, contents: nil)
    defer { try? FileManager.default.removeItem(atPath: flag) }
    let workspaces = d.workspaces
    let creating = Task.detached { try workspaces.createWorkspace(in: repo) }
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: asked) })   // its branch is being read on the host
    let synced = OSAllocatedUnfairLock(initialState: false)
    let syncing = Task.detached {
        try workspaces.syncMainWorkspaces()
        synced.withLock { $0 = true }
    }
    #expect(try await waitFor { synced.withLock { $0 } })   // not behind that read, which the host still holds
    try FileManager.default.removeItem(atPath: flag)   // the host answers
    try await syncing.value
    _ = try await creating.value
}

/// The project's folder follows its checked-out branch; one git can't read (its folder away, git timing out) keeps the
/// branch it had, not the project's base written over it.
@Test func aBranchThatCantBeReadIsntWrittenAsTheBase() async throws {
    let w = try await world()
    defer { w.d.stop() }
    try Git.run(["checkout", "-q", "-b", "feature"], cwd: w.repo.path, remotes: .none)
    try w.d.workspaces.syncMainWorkspaces()
    func branch() throws -> String? {
        try w.d.store.worktrees(repo: w.repo.id).first { $0.path == w.repo.path }?.branch
    }
    #expect(try branch() == "feature")
    let git = w.repo.path + "/.git"
    try FileManager.default.moveItem(atPath: git, toPath: git + "-away")
    defer { try? FileManager.default.moveItem(atPath: git + "-away", toPath: git) }
    try w.d.workspaces.syncMainWorkspaces()
    #expect(try branch() == "feature")
}

/// Remove Clean Worktrees puts each folder in the Trash, the ignored files git doesn't count (.env) with it, and keeps the
/// one a paused agent last worked in.
@Test func removingCleanWorktreesTrashesIgnoredFilesAndKeepsAPausedAgentsFolder() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let repo = w.repo.path
    try ".env\n".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
    let clean = w.root.appendingPathComponent("clean").path, paused = w.root.appendingPathComponent("paused").path
    for (p, b) in [(clean, "clean"), (paused, "paused")] {
        try Git.run(["worktree", "add", "-q", "-b", b, p], cwd: repo, remotes: .none)
    }
    let secret = "SECRET=\(UUID())\n"   // this test's own, among every test's in the Trash
    try secret.write(toFile: clean + "/.env", atomically: true, encoding: .utf8)
    var s = Session(cwd: paused, command: "agent")
    s.status = .paused
    try w.d.store.save(s)
    let listed = try Git.linkedWorktrees(repo, remotes: .none).map(\.path)
    let res = try await w.c.call(RepoRemoveWorktrees(id: w.repo.id, paths: listed))
    #expect(res.removed.count == 1 && res.kept.count == 1 && res.kept.values.first?.contains("agent") == true, "\(res)")
    #expect(FileManager.default.fileExists(atPath: paused) && !FileManager.default.fileExists(atPath: clean))
    #expect(inTheTrash("clean/.env", holding: secret))
}

/// What a discard throws away is kept for its Undo first: when it can't be (a full disk; here, a file where its folder
/// goes), nothing is discarded.
@Test func aDiscardThatCantKeepItsUndoChangesNothing() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "keep")
    try "hello\nmine\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    try Data().write(to: w.d.sourceControl.discards)
    await expectRefusal(says: "its Undo couldn't be kept") {
        try await w.c.call(GitDiscard(id: wt.id, files: ["a.txt"]))
    }
    #expect(try String(contentsOfFile: wt.path + "/a.txt", encoding: .utf8) == "hello\nmine\n")
}

/// A branch an agent made for a helper goes when its last session does and nothing is only there; a new link in it (the
/// project's Vendor) is no work, a new file is. The user's own branch stays whatever its agents do, and so does one of
/// the user's an agent only checked out (`--existing`): its folder goes, the branch doesn't.
@Test func anAgentsBranchGoesWithItsLastSession() async throws {
    let w = try await world(agents: [
        AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "sleep 30", "x"])
    ])
    defer { w.d.stop() }
    var clean = try await workspace(w, "helper/clean"), work = try await workspace(w, "helper/work")
    let mine = try await workspace(w, "mine")
    try Git.run(["branch", "theirs"], cwd: w.repo.path, remotes: .none)
    var asked = WorktreeCreate(repoId: w.repo.id, branch: "theirs", setup: false)
    asked.existing = true
    var theirs = try await w.c.call(asked).worktree
    theirs.createdAt = Date().addingTimeInterval(120)   // the branch was there two minutes before
    clean.madeBy = "AGENT"
    work.madeBy = "AGENT"
    theirs.madeBy = "AGENT"
    try w.d.store.save(clean)
    try w.d.store.save(work)
    try w.d.store.save(theirs)
    try FileManager.default.createSymbolicLink(atPath: clean.path + "/Vendor", withDestinationPath: w.repo.path)
    try "notes".write(toFile: work.path + "/notes.txt", atomically: true, encoding: .utf8)
    #expect(try !Git.isDirty(clean.path, remotes: .none) && Git.isDirty(work.path, remotes: .none))
    for workspace in [clean, work, mine, theirs] {
        w.d.sessions.discard(try await w.c.call(SessionCreate(worktreeId: workspace.id, agent: "sleepy")))
    }
    #expect(try await waitFor(5) { try w.d.store.worktree(clean.id) == nil && w.d.store.worktree(theirs.id) == nil })
    w.d.workspaces.headQueue.sync {}   // the other two were looked at as well
    #expect(try w.d.store.worktree(clean.id) == nil && !Git.branchExists(w.repo.path, "helper/clean", remotes: .none))
    #expect(try w.d.store.worktree(work.id) != nil && w.d.store.worktree(mine.id) != nil)
    #expect(
        Git.branchExists(w.repo.path, "theirs", remotes: .none) && !FileManager.default.fileExists(atPath: theirs.path))
}

/// Removing a workspace opened on a branch that was there already (`--existing`) removes its folder and keeps the
/// branch, whoever asks; one Kelp made for it goes with it.
@Test func removingAWorkspaceKeepsABranchItDidntMake() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let made = try await workspace(w, "made")
    try Git.run(["branch", "theirs"], cwd: w.repo.path, remotes: .none)
    var asked = WorktreeCreate(repoId: w.repo.id, branch: "theirs", setup: false)
    asked.existing = true
    var theirs = try await w.c.call(asked).worktree
    theirs.createdAt = Date().addingTimeInterval(120)   // the branch was there two minutes before
    try w.d.store.save(theirs)
    for workspace in [made, theirs] { _ = try await w.c.call(WorktreeRemove(id: workspace.id)) }
    #expect(
        !FileManager.default.fileExists(atPath: theirs.path) && Git.branchExists(w.repo.path, "theirs", remotes: .none))
    #expect(!Git.branchExists(w.repo.path, "made", remotes: .none))
}

/// A branch group whose work is in the base branch goes by itself: removed with nobody on it, archived with its chat.
/// One opened on a branch that was there already, one with uncommitted files and one with nothing done stay.
@Test func aBranchWhoseWorkLandedGoesByItself() async throws {
    let w = try await world(agents: [
        AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "sleep 30", "x"])
    ])
    defer { w.d.stop() }
    try Git.run(["branch", "old"], cwd: w.repo.path, remotes: .none)   // there before any group
    let done = try await workspace(w, "done"), chatted = try await workspace(w, "chatted")
    let dirty = try await workspace(w, "dirty"), idle = try await workspace(w, "idle")
    var asked = WorktreeCreate(repoId: w.repo.id, branch: "old", setup: false)
    asked.existing = true
    let old = try await w.c.call(asked).worktree
    func commit(_ ws: Worktree, _ name: String) throws {
        try name.write(toFile: ws.path + "/" + name, atomically: true, encoding: .utf8)
        try Git.run(["add", name], cwd: ws.path, remotes: .none)
        try Git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", name], cwd: ws.path, remotes: .none)
    }
    for ws in [done, chatted, dirty] { try commit(ws, ws.branch + ".txt") }
    try "wip".write(toFile: dirty.path + "/wip.txt", atomically: true, encoding: .utf8)
    _ = try await w.c.call(SessionCreate(worktreeId: chatted.id, agent: "sleepy"))
    for branch in ["done", "chatted", "dirty", "old"] {
        try Git.run(["merge", "-q", "--no-edit", branch], cwd: w.repo.path, remotes: .none)
    }
    w.d.workspaces.headQueue.sync { w.d.workspaces.tidyBranches(in: w.repo.id) }
    #expect(try w.d.store.worktree(done.id) == nil && !Git.branchExists(w.repo.path, "done", remotes: .none))
    #expect(try w.d.store.worktree(chatted.id)?.archived == true)
    for kept in [dirty, idle, old] { #expect(try w.d.store.worktree(kept.id)?.archived == false) }
}

/// Only the project's own HEAD moves its workspaces: git writes FETCH_HEAD and ORIG_HEAD on a fetch or a merge, and a
/// remote's or a linked worktree's HEAD, without its folder switching branch.
@Test func onlyTheProjectsOwnHeadMovesItsWorkspaces() {
    #expect(Workspaces.movesHead(["/p/.git/index", "/p/.git/HEAD"]))
    let others = ["FETCH_HEAD", "ORIG_HEAD", "refs/remotes/origin/HEAD", "worktrees/fix/HEAD"].map { "/p/.git/" + $0 }
    #expect(!Workspaces.movesHead(others))
}
