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
