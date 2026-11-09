import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// A fork goes on from a copy of the conversation (`--fork-session`), never under the id the original keeps; an agent
/// that can't copy its conversation, or one with nothing typed yet, is refused.
@Test func aForkGoesOnFromACopyOfTheConversation() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let claude = AgentManifest.presets.first { $0.id == "claude" }!
    var old = Session(cwd: "/tmp", command: "claude", agent: "claude")
    old.argv = ["claude", "--model", "opus", "--resume", "abc"]
    #expect(
        try SessionFork.argv(old, claude, w.d.sessions)
            == ["claude", "--model", "opus", "--resume", "abc", "--fork-session"])
    old.argv = ["claude", "--session-id", "new-one"]   // pinned, nothing typed: nothing to copy
    #expect(throws: RPCError.self) { try SessionFork.argv(old, claude, w.d.sessions) }
    let gemini = AgentManifest.presets.first { $0.id == "gemini" }!
    #expect(throws: RPCError.self) {
        try SessionFork.argv(Session(cwd: "/tmp", command: "gemini", agent: "gemini"), gemini, w.d.sessions)
    }
}
