import Agents
import Core
import Foundation
import GitKit
import Testing

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
    await #expect(throws: (any Error).self) { try await w.c.call(WorktreeRemove(id: wt.id)) }
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
    #expect(try Git.linkedWorktrees(w.repo.path, remotes: .none).isEmpty && !Git.branchExists(w.repo.path, "half-gone", remotes: .none))
    // Its own commit: refused, the record stays, until told to drop it.
    let own = try await workspace(w, "own-commit")
    try Git.run(["commit", "-q", "--allow-empty", "-m", "only here"], cwd: own.path, remotes: .none)
    try FileManager.default.moveItem(atPath: own.path, toPath: tmp().path + "/trashed")
    await #expect(throws: (any Error).self) { try await w.c.call(WorktreeRemove(id: own.id)) }
    #expect(try Git.branchExists(w.repo.path, "own-commit", remotes: .none) && w.d.store.worktree(own.id) != nil)
    _ = try await w.c.call(WorktreeRemove(id: own.id, dropCommits: true))
    #expect(try Git.linkedWorktrees(w.repo.path, remotes: .none).isEmpty && !Git.branchExists(w.repo.path, "own-commit", remotes: .none))
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
    let flag = shim.appendingPathComponent("slow-host").path, asked = shim.appendingPathComponent("slow-asked").path
    try? FileManager.default.removeItem(atPath: asked)
    FileManager.default.createFile(atPath: flag, contents: nil)
    defer { try? FileManager.default.removeItem(atPath: flag) }
    let workspaces = d.workspaces
    let creating = Task.detached { try workspaces.createWorkspace(in: repo) }
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: asked) })   // its branch is being read on the host, for 3 s
    let start = Date()
    try workspaces.syncMainWorkspaces()
    #expect(Date().timeIntervalSince(start) < 2.5)   // not behind that read
    _ = try await creating.value
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
    try "SECRET=1\n".write(toFile: clean + "/.env", atomically: true, encoding: .utf8)
    var s = Session(cwd: paused, command: "agent")
    s.status = .paused
    try w.d.store.save(s)
    let listed = try Git.linkedWorktrees(repo, remotes: .none).map(\.path)
    let res = try await w.c.call(RepoRemoveWorktrees(id: w.repo.id, paths: listed))
    #expect(res.removed.count == 1 && res.kept.count == 1 && res.kept.values.first?.contains("agent") == true, "\(res)")
    #expect(FileManager.default.fileExists(atPath: paused) && !FileManager.default.fileExists(atPath: clean))
    let trash = try #require(ProcessInfo.processInfo.environment["KELP_TRASH"])
    let trashed = (FileManager.default.enumerator(atPath: trash)?.allObjects as? [String] ?? []).filter {
        $0.hasSuffix("clean/.env")
    }
    #expect(!trashed.isEmpty)
}

/// What a discard throws away is kept for its Undo first: when it can't be (a full disk; here, a file where its folder
/// goes), nothing is discarded.
@Test func aDiscardThatCantKeepItsUndoChangesNothing() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await workspace(w, "keep")
    try "hello\nmine\n".write(toFile: wt.path + "/a.txt", atomically: true, encoding: .utf8)
    try Data().write(to: w.d.sourceControl.discards)
    await #expect(throws: RPCError.self) { try await w.c.call(GitDiscard(id: wt.id, files: ["a.txt"])) }
    #expect(try String(contentsOfFile: wt.path + "/a.txt", encoding: .utf8) == "hello\nmine\n")
}
