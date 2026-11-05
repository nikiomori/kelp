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

/// A new workspace in a remote project whose host is slow to answer: every other project's workspaces sync meanwhile.
@Test func aSlowHostDoesntHoldOtherProjectsWorkspaces() async throws {
    _ = localSSH
    let (d, c, _) = try daemon(); defer { d.stop() }
    let there = tmp().appendingPathComponent("slow-host").path
    try FileManager.default.createDirectory(atPath: there, withIntermediateDirectories: true)
    try Git.run(["init", "-q", "-b", "main"], cwd: there); try Git.run(["commit", "-q", "--allow-empty", "-m", "a"], cwd: there)
    let repo = try await c.call(RepoAddRemote(host: "box", path: there))
    let flag = URL(fileURLWithPath: localSSH).deletingLastPathComponent().appendingPathComponent("slow-host").path
    FileManager.default.createFile(atPath: flag, contents: nil); defer { try? FileManager.default.removeItem(atPath: flag) }
    let workspaces = d.workspaces
    let creating = Task.detached { try workspaces.createDesk(in: repo) }
    try await Task.sleep(for: .milliseconds(500))   // its branch is being read on the host
    let start = Date()
    try workspaces.syncMainWorkspaces()
    #expect(Date().timeIntervalSince(start) < 1.5)
    _ = try await creating.value
}

/// Remove Clean Worktrees puts each folder in the Trash, the ignored files git doesn't count (.env) with it, and keeps the
/// one a paused agent last worked in.
@Test func removingCleanWorktreesTrashesIgnoredFilesAndKeepsAPausedAgentsFolder() async throws {
    let w = try await world(); defer { w.d.stop() }
    let repo = w.repo.path
    try ".env\n".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
    let clean = w.root.appendingPathComponent("clean").path, paused = w.root.appendingPathComponent("paused").path
    for (p, b) in [(clean, "clean"), (paused, "paused")] { try Git.run(["worktree", "add", "-q", "-b", b, p], cwd: repo) }
    try "SECRET=1\n".write(toFile: clean + "/.env", atomically: true, encoding: .utf8)
    var s = Session(cwd: paused, command: "agent"); s.status = .hibernated
    try w.d.store.save(s)
    let listed = try Git.linkedWorktrees(repo).map(\.path)
    let res = try await w.c.call(RepoRemoveWorktrees(id: w.repo.id, paths: listed))
    #expect(res.removed.count == 1 && res.kept.count == 1 && res.kept.values.first?.contains("agent") == true, "\(res)")
    #expect(FileManager.default.fileExists(atPath: paused) && !FileManager.default.fileExists(atPath: clean))
    let trash = try #require(ProcessInfo.processInfo.environment["KELP_TRASH"])
    let trashed = (FileManager.default.enumerator(atPath: trash)?.allObjects as? [String] ?? []).filter { $0.hasSuffix("clean/.env") }
    #expect(!trashed.isEmpty)
}
