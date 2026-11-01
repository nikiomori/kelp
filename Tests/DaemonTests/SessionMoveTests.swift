import Foundation
import Testing
import Core
import GitKit
@testable import Daemon

/// A running agent changes screens within its folder and goes on as it was; a checkout elsewhere is other files.
@Test func anAgentMovesBetweenScreensOfItsFolder() async throws {
    let (d, c, _, repo) = try await world(); defer { d.stop() }
    let desk: Worktree = try await c.call("workspace.create", .obj(["repoId": .string(repo.id)]), as: Worktree.self)
    let first = try #require(try await c.call("worktree.list", .obj(["repoId": .string(repo.id)]), as: [Worktree].self).first { $0.id != desk.id })
    let s: Session = try await c.call("session.create", .obj(["worktreeId": .string(first.id), "command": "sleep 60"]), as: Session.self)
    func now() async throws -> Session? { try await c.call("session.list", as: [Session].self).first { $0.id == s.id } }
    _ = try await c.call("session.move", .obj(["id": .string(s.id), "worktreeId": .string(desk.id)]))
    #expect(try await waitFor(5) { try await now()?.worktreeId == desk.id })
    let moved = try await now()
    #expect(moved?.status != .exited && moved?.pid == s.pid)   // the same process
    let branch: Worktree = try await c.call("worktree.create", .obj(["repoId": .string(repo.id), "branch": "elsewhere"]), as: Worktree.self)
    await #expect(throws: RPCError.self) {
        try await c.call("session.move", .obj(["id": .string(s.id), "worktreeId": .string(branch.id)]))
    }
    #expect(try await now()?.worktreeId == desk.id)
}
