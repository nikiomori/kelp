import Foundation
import Testing
import Core
import GitKit
import Agents
@testable import Daemon

/// A branch group whose removal fails (here: locked) keeps its turns' snapshots; removed, it lets them go from the
/// project's repository, its folder gone.
@Test func aFailedWorkspaceRemovalKeepsItsTurnRefs() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")]); defer { w.d.stop() }
    let wt = try await desk(w, "locked-turns")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    try #require(w.d.sessions.existing(s.id)).noteTurn(.working)
    #expect(try await waitFor(5) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty })
    let refs = { try Git.run(["for-each-ref", "refs/kelp/turns/"], cwd: w.repo.path) }
    #expect(try !refs().isEmpty)
    try Git.run(["worktree", "lock", wt.path], cwd: w.repo.path)
    await #expect(throws: (any Error).self) { try await w.c.call(WorktreeRemove(id: wt.id)) }
    #expect(try !refs().isEmpty)
    try Git.run(["worktree", "unlock", wt.path], cwd: w.repo.path)
    _ = try await w.c.call(WorktreeRemove(id: wt.id))
    #expect(try refs().isEmpty)
}

/// A removal that stopped after its folder went to the Trash, tried again: git's record of the worktree and its branch go
/// too, the branch only by the same rule (its commits elsewhere, or dropped on purpose).
@Test func removingAWorkspaceWhoseFolderIsGoneForgetsItInGit() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "half-gone")
    try FileManager.default.moveItem(atPath: wt.path, toPath: tmp().path + "/trashed")
    _ = try await w.c.call(WorktreeRemove(id: wt.id))
    #expect(try Git.linkedWorktrees(w.repo.path).isEmpty && !Git.branchExists(w.repo.path, "half-gone"))
    // Its own commit: refused, the record stays, until told to drop it.
    let own = try await desk(w, "own-commit")
    try Git.run(["commit", "-q", "--allow-empty", "-m", "only here"], cwd: own.path)
    try FileManager.default.moveItem(atPath: own.path, toPath: tmp().path + "/trashed")
    await #expect(throws: (any Error).self) { try await w.c.call(WorktreeRemove(id: own.id)) }
    #expect(try Git.branchExists(w.repo.path, "own-commit") && w.d.store.worktree(own.id) != nil)
    _ = try await w.c.call(WorktreeRemove(id: own.id, dropCommits: true))
    #expect(try Git.linkedWorktrees(w.repo.path).isEmpty && !Git.branchExists(w.repo.path, "own-commit"))
}
