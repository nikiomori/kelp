import Foundation
import Testing
import Core
@testable import Daemon

/// A Claude Code session's base as its /context counts it: a copy of it run in the session's folder with its model and
/// skills (not its session id) prints it, once, then it's kept; another agent's isn't asked.
@Test func claudeSetupAsksACopyOfClaudeCodeOnce() throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let dir = root.appendingPathComponent("proj"), log = root.appendingPathComponent("asked.txt"), fake = root.appendingPathComponent("claude")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try """
    #!/bin/sh
    echo "$(pwd -P) $*" >> '\(log.path)'
    printf '### Estimated usage by category\\n| Category | Tokens | Percentage |\\n|---|---|---|\\n| System prompt | 2.5k | 0.2%% |\\n| Skills | 1k | 0.1%% |\\n'
    """.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    var s = Session(cwd: dir.path, command: "claude", agent: "claude", argv: [fake.path, "--model", "opus", "--plugin-dir", "/x", "--session-id", "abc"])
    let setup = try #require(d.sessions.claudeSetup(s))
    #expect(setup.parts.map(\.tokens) == [2500, 1000])
    #expect(d.sessions.claudeSetup(s) == setup)
    let asked = try String(contentsOf: log, encoding: .utf8)
    #expect(asked.hasSuffix("/proj -p /context --no-session-persistence --model opus --plugin-dir /x\n") && asked.split(separator: "\n").count == 1)
    s.agent = "codex"
    #expect(d.sessions.claudeSetup(s) == nil)
}
