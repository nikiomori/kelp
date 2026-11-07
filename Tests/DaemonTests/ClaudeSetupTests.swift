import Core
import Foundation
import Testing

@testable import Daemon

private func fakeClaude(_ root: URL, log: URL) throws -> URL {
    let fake = root.appendingPathComponent("claude")
    try """
    #!/bin/sh
    echo "$*" >> '\(log.path)'
    printf '### Estimated usage by category\\n| Category | Tokens | Percentage |\\n|---|---|---|\\n| System prompt | 2.5k | 0.2%% |\\n| Skills | 1k | 0.1%% |\\n'
    """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    return fake
}

/// A Claude Code session's base as its /context counts it: a copy of it run in the session's folder with its model and
/// skills (not its session id) prints it, once, then it's kept; another agent's isn't asked. Nobody watches that copy, so
/// it runs no hook or MCP server of the project's (`-p` asks nothing, and a real one was seen to run them).
@Test func claudeSetupAsksACopyOfClaudeCodeOnce() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), log = w.root.appendingPathComponent("asked.txt"),
        fake = try fakeClaude(w.root, log: log)
    var s = Session(
        worktreeId: wt.id, cwd: wt.path, command: "claude", agent: "claude",
        argv: [fake.path, "--model", "opus", "--plugin-dir", "/x", "--session-id", "abc"])
    let setup = try #require(w.d.sessions.claudeSetup(s))
    #expect(setup.parts.map(\.tokens) == [2500, 1000])
    #expect(w.d.sessions.claudeSetup(s) == setup)
    let asked = try String(contentsOf: log, encoding: .utf8)
    #expect(
        asked
            == #"-p /context --no-session-persistence --strict-mcp-config --settings {"disableAllHooks":true} --model opus --plugin-dir /x"#
            + "\n")
    s.agent = "codex"
    #expect(w.d.sessions.claudeSetup(s) == nil)
}

/// A branch that brought its own agent config (someone's PR) isn't opened behind the user's back, nor a folder of no project.
@Test func claudeSetupLeavesAChangedAgentConfigAlone() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), log = w.root.appendingPathComponent("asked.txt"),
        fake = try fakeClaude(w.root, log: log)
    try "{}".write(toFile: wt.path + "/.mcp.json", atomically: true, encoding: .utf8)
    #expect(
        w.d.sessions.claudeSetup(
            Session(worktreeId: wt.id, cwd: wt.path, command: "claude", agent: "claude", argv: [fake.path])) == nil)
    #expect(
        w.d.sessions.claudeSetup(
            Session(cwd: w.root.path, command: "claude", agent: "claude", argv: [fake.path, "--model", "x"])) == nil)
    #expect(!FileManager.default.fileExists(atPath: log.path))
}
