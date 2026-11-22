import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// Prints what it was started with, then waits.
private let fake = AgentManifest(
    id: "fake", name: "Fake", command: "/bin/zsh", args: ["-c", #"echo "url=$LOCAL_URL args=$*"; exec cat"#, "fake"])

/// An extension starts Claude Code on a local model's server with `--env` and `--arg`: the program gets both, and a
/// restart reaches the same server (the variables are the session's, not the agent's).
@Test func aSessionsOwnVariablesAndArgumentsSurviveARestart() async throws {
    let w = try await world(agents: [fake])
    defer { w.d.stop() }
    let workspace = try await firstWorkspace(w)
    var create = SessionCreate(worktreeId: workspace.id, agent: "fake")
    (create.env, create.args) = (["LOCAL_URL": "http://127.0.0.1:11434"], ["--oss"])
    let first = try await w.c.call(create)
    #expect(first.env == ["LOCAL_URL": "http://127.0.0.1:11434"])
    let shown = "url=http://127.0.0.1:11434 args=--oss"
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: first.id)).contains(shown) })
    let again = try await w.c.call(SessionRestart(id: first.id, resume: false))
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: again.id)).contains(shown) })
    let plain = try await w.c.call(SessionCreate(worktreeId: workspace.id, agent: "fake"))
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: plain.id)).contains("url= args=") })
}
