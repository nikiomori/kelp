import AgentData
import Agents
import Core
import Foundation
import Testing

@testable import Daemon

/// Two threads for the same project. The project and home names also exercise the remote shell's quoting.
private struct CodexHost {
    var home = tmp().appendingPathComponent("codex ' $(false)")
    var session = Session(cwd: "/same project", command: "codex", agent: Session.codexAgent, argv: ["codex"])

    func rollout(_ id: UUID, text: String) throws -> URL {
        let dir = home.appendingPathComponent("sessions/2026/01/01")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2026-01-01T10-00-00-\(id.uuidString.lowercased()).jsonl")
        try Data(text.utf8).write(to: file)
        return file
    }

    func read(_ thread: UUID? = nil, transcript: String? = nil, path: String = LoginPath.value) throws -> Data? {
        guard let script = Conversations.codexTailScript(session, thread: thread, transcript: transcript) else {
            return nil
        }
        return try Subprocess.output(
            ["/bin/sh", "-c", script], cwd: "/", env: ["CODEX_HOME": home.path, "PATH": path], timeLimit: 10)
    }
}

@Test func remoteCodexResumesOnlyTheNamedThreadAndBoundsItsTail() throws {
    let original = UUID(), current = UUID()
    var host = CodexHost()
    _ = try host.rollout(original, text: "original")
    let file = try host.rollout(current, text: String(repeating: "x", count: Conversations.remoteTailBytes + 1))
    host.session.argv += ["resume", original.uuidString]
    #expect(try host.read() == Data("original".utf8))
    #expect(try host.read(current)?.count == Conversations.remoteTailBytes)
    #expect(try host.read(transcript: file.path)?.count == Conversations.remoteTailBytes)
    #expect(try host.read(UUID())?.isEmpty == true, "a missing current thread never falls back to the initial chat")
    for args in [
        ["resume", "--last"], ["resume", "$(echo wrong)"], ["fork", original.uuidString],
        ["-m", "resume", original.uuidString], ["--", "resume", original.uuidString], []
    ] {
        host.session.argv = ["codex"] + args
        #expect(try host.read(transcript: "/etc/passwd") == nil)
    }
}

private let hostTmux = try? LoginPath.resolve("tmux")

@Test(.enabled(if: hostTmux != nil)) func remoteCodexOpenRolloutOverridesLaunchResume() throws {
    var host = CodexHost()
    let original = UUID(), name = Tmux.own()
    _ = try host.rollout(original, text: "original")
    let file = try host.rollout(UUID(), text: "current")
    // Stand in for the program name only. tmux, the pane PID, the open descriptor and lsof are real.
    let bin = tmp(), ps = bin.appendingPathComponent("ps")
    try "#!/bin/sh\n/bin/ps \"$@\" | sed 's|.*/sleep$|codex|'\n".write(to: ps, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)
    let tmux = try #require(hostTmux)
    let run = "exec 3<\(ShellQuote.word(file.path)); exec /bin/sleep 60"
    try Subprocess.output([tmux, "new-session", "-d", "-s", name, "/bin/sh", "-c", run], cwd: "/", timeLimit: 5)
    defer { _ = try? Subprocess.output([tmux, "kill-session", "-t", "=" + name], cwd: "/", timeLimit: 5) }
    host.session.tmux = name
    host.session.argv += ["resume", original.uuidString]
    #expect(try host.read(path: bin.path + ":" + LoginPath.value) == Data("current".utf8))
    host.session.tmux = Tmux.own()
    host.session.argv = ["codex"]
    #expect(try host.read()?.isEmpty == true, "an absent target cannot select a different tmux session")
}

@Test func remoteCodexHookReportsFollowTheMainThread() throws {
    let host = CodexHost()
    var record = host.session
    record.tmux = Tmux.own()
    var state = LiveSession.State(
        record: record, manifest: AgentManifest(id: "codex", name: "Codex", command: "codex"),
        logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: record.id))
    let current = UUID()
    for report in [
        "state=working:conv=\(UUID())", "state=done:conv=\(current)", "state=working:id=child:conv=\(UUID())",
        "state=working:conv=bad"
    ] {
        let osc = ProgramStatus.prefix + report + "\u{07}"
        _ = state.readReports(osc, Data(osc.utf8))
    }
    #expect(state.record.codexThread == current)
    let tail = Data("""
        partial line
        {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}
        """.utf8)
    #expect(CodexHistory.lastReply(tail: tail) == "done")
    let cutShort = Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}".utf8)
    #expect(CodexHistory.lastReply(tail: tail + cutShort) == nil)
}

@Test func remoteCodexPhoneReadsOneTailOverAnExistingConnection() async throws {
    let original = UUID(), current = UUID()
    let codex = AgentManifest(
        id: "codex", name: "Codex", command: "/bin/bash",
        args: ["-c", "sleep 30", "codex", "resume", original.uuidString])
    let (d, c, _) = try daemon(agents: [codex])
    defer { d.stop() }
    let hostname = "box-" + UUID().uuidString
    let (_, workspace, _) = try await remoteProject(c, host: hostname)
    let session = try await c.call(SessionCreate(worktreeId: workspace.id, agent: Session.codexAgent))
    let live = try #require(d.sessions.existing(session.id))
    var host = CodexHost()
    host.home = CodexHistory.defaultRoot.deletingLastPathComponent()
    _ = try host.rollout(original, text: "old conversation")
    _ = try host.rollout(current, text: #"""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"My question"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"My reply"}]}}
        {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Finished"}}
        """#)
    _ = live.report(.init(state: "done", conv: current.uuidString))
    #expect(try await c.call(SessionLastReply(id: session.id)) == "Finished")
    let bin = URL(fileURLWithPath: localSSH).deletingLastPathComponent()
    func reads() throws -> Int {
        let log = try String(contentsOf: bin.appendingPathComponent("ssh.log"), encoding: .utf8)
        return log.components(separatedBy: "rollout-*-" + current.uuidString.lowercased()).count - 1
    }
    let before = try reads()
    let fields = await d.sessions.phone.conversationFields(of: session)
    #expect(fields["lastReply"]?.string == "Finished")
    #expect(fields["turns"]?.array?.compactMap { $0["text"]?.string } == ["My question", "My reply"])
    #expect(try reads() == before + 1)
    let print = try #require(fields["conversation"]?.string)
    let unchanged = await d.sessions.phone.conversationFields(of: session, seen: print)
    #expect(unchanged == ["conversation": .string(print), "same": .bool(true)], "what the phone has isn't sent again")
    #expect(try reads() == before + 2)
    try Data().write(to: bin.appendingPathComponent("down-" + hostname))
    #expect(await d.sessions.phone.conversationFields(of: session) == ["lastReply": .null])
    #expect(try reads() == before + 2)
    try FileManager.default.removeItem(at: bin.appendingPathComponent("down-" + hostname))
    _ = try await c.call(SessionKill(id: session.id))
    try await waitFor { try d.sessions.store.session(session.id)?.status == .exited }
    let ended = try #require(try d.sessions.store.session(session.id))
    #expect(ended.codexThread == current)
    let reader = d.agentUsage.conversations
    let report = ProgramStatus.prefix + "state=done:conv=\(current)\u{07}"
    let printedAfter = String(repeating: "output\r\n", count: 20_000)   // 160 KB the TUI printed after the report
    try Data((report + printedAfter).utf8).write(to: live.logURL)
    let archived = reader.phoneConversation(of: ended, live: nil)
    #expect(archived.turns.map(\.text) == ["My question", "My reply"])
    #expect(archived.reply == nil)
    var legacy = ended
    legacy.codexThread = nil
    #expect(reader.phoneConversation(of: legacy, live: nil).turns == archived.turns)
    try FileManager.default.removeItem(at: live.logURL)
    #expect(reader.phoneConversation(of: ended, live: nil).turns == archived.turns)
}
