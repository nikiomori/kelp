import Agents
import Core
import Foundation
import Testing

@testable import Daemon

private let fake = AgentManifest(id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", "cat"])

/// A reviewer is one by its record, not its title: the role it's started with is kept, and a restart keeps it.
@Test func aReviewersRoleIsKeptAndSurvivesARestart() async throws {
    let w = try await world(agents: [fake])
    defer { w.d.stop() }
    let workspace = try await firstWorkspace(w)
    let reviewer = try await w.c.call(SessionCreate(worktreeId: workspace.id, agent: "fake").started(as: .reviewer))
    #expect(reviewer.role == .reviewer)
    #expect(try await w.c.call(SessionList()).first { $0.id == reviewer.id }?.role == .reviewer)
    let again = try await w.c.call(SessionRestart(id: reviewer.id, resume: false))
    #expect(again.role == .reviewer)
    let plain = try await w.c.call(SessionCreate(worktreeId: workspace.id, agent: "fake"))
    #expect(plain.role == nil)
}
