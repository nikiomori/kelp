import Core
import Foundation
import TestSupport
import Testing

@testable import Agents

/// Runs the generated command with a stand-in for tmux and with fd 3 as the agent's tty.
private struct HostHookRunner {
    let bin = tmp()
    var kept: URL { bin.appendingPathComponent("kept") }

    init() throws {
        for (name, body) in [("tmux", "echo \"$@\" > \(kept.path)"), ("ps", "echo fd/3")] {
            let f = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
    }

    func run(_ command: String, _ payload: String, inTmux: Bool = true) throws -> String {
        let tty = bin.appendingPathComponent("tty")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s \"$PAYLOAD\" | /bin/sh -c \"$HOOK\" 3>\(tty.path)"]
        p.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin", "PAYLOAD": payload, "HOOK": command, "TMUX": inTmux ? "x" : "",
            "CODEX_HOME": bin.path
        ]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return try String(contentsOf: tty, encoding: .utf8)
    }
}

private func wrapped(_ report: String) -> String { "\u{1B}Ptmux;\u{1B}\u{1B}]7501;\(report)\u{07}\u{1B}\\" }

@Test func aHostsHooksWriteThroughTmuxAndKeepTheReport() throws {
    let runner = try HostHookRunner()
    let settings = try JSONDecoder().decode(JSONValue.self, from: Data(Hooks.hostSettingsJSON().utf8))
    func run(_ event: String, _ payload: String, inTmux: Bool = true) throws -> String {
        let command = try #require(settings["hooks"]?[event]?.array?.first?["hooks"]?.array?.first?["command"]?.string)
        return try runner.run(command, payload, inTmux: inTmux)
    }
    let id = "0f3c9a2e-5b7d-4e1a-9c2f-1a2b3c4d5e6f"
    #expect(try run("Stop", #"{"session_id":"\#(id)","background_tasks":[]}"#) == wrapped("state=done:conv=\(id)"))
    #expect(
        try String(contentsOf: runner.kept, encoding: .utf8) == "set-option -q @kelp_status state=done:conv=\(id)\n")
    #expect(try run("UserPromptSubmit", #"{"session_id": "\#(id)"}"#) == wrapped("state=working:conv=\(id)"))
    let failed = #"{"error":"overloaded","last_assistant_message":"API Error: Overloaded"}"#
    #expect(try run("StopFailure", failed) == wrapped("state=error:hook=" + Data(failed.utf8).base64EncodedString()))
    // A dialog says what it asks, so Kelp offers Allow / Deny; one too long for a report, its tool and file.
    let ask = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
    #expect(
        try run("PermissionRequest", ask)
            == wrapped("state=blocked:kind=permission:hook=" + Data(ask.utf8).base64EncodedString()))
    let long =
        #"{"tool_name":"Edit","tool_input":{"file_path":"/srv/app/a.swift","old_string":"\#(String(repeating: "x", count: 4000))"}}"#
    let short = #"{"tool_name":"Edit","tool_input":{"file_path":"/srv/app/a.swift"}}"#
    #expect(
        try run("PermissionRequest", long)
            == wrapped("state=blocked:kind=permission:hook=" + Data(short.utf8).base64EncodedString()))
    // A tool's end doesn't end a dialog; its batch does, unless it's a subagent's.
    #expect(try run("PostToolBatch", #"{"agent_id":"a1"}"#) == "")
    #expect(try run("PostToolBatch", "{}") == wrapped("state=working"))
    #expect(try run("Stop", #"{"background_tasks":[{"id":"a","type":"subagent"}]}"#) == "")   // the turn isn't over
    #expect(try run("Stop", #"{"background_tasks": [{"id": "a", "type": "workflow"}]}"#) == "")
    #expect(
        try run("Stop", #"{"background_tasks":[{"id":"a","type":"shell"},{"id":"b","type":"memory"}]}"#)
            == wrapped("state=done:conv="))   // nothing wakes it
    #expect(
        try run("Stop", #"{"last_assistant_message":"\"type\":\"subagent\"","background_tasks":[]}"#)
            == wrapped("state=done:conv="))
    let title = Data("Explore".utf8).base64EncodedString()
    #expect(
        try run("SubagentStart", #"{"agent_id":"a1","agent_type":"Explore"}"#)
            == wrapped("state=working:id=a1:title=\(title)"))
    #expect(try run("SubagentStop", #"{"agent_id":"a1"}"#) == wrapped("state=clear:id=a1"))
    #expect(try run("Stop", "{}", inTmux: false) == "")
    // tmux takes the whole command as one message, about 16 KB at most.
    #expect(try Hooks.hostSettingsJSON().utf8.count < 6000)
}

@Test func aHostsCodexReportsOnlyTheRootTurn() throws {
    let runner = try HostHookRunner()
    let parent = "019f0001-3030-751b-8451-063a514b7b14", child = "019f0002-4033-721c-a711-1c42eaca2641"
    let resumed = "019f0003-176c-7649-8121-a7eda120236e"
    let quoted = #"Check {"session_id":"\#(child)","agent_id":"\#(child)"}"#
    let day = runner.bin.appendingPathComponent("sessions/2026/11/25")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    func rollout(_ id: String) -> String {
        day.appendingPathComponent("rollout-2026-11-25T09-05-21-\(id).jsonl").path
    }
    func writeRollout(_ id: String, version: String, childOf: String? = nil) throws {
        let at: JSONValue = "2026-11-25T09:05:21.000Z"
        var meta: [String: JSONValue] = [
            "id": .string(id), "timestamp": at, "cwd": "/srv/app", "cli_version": .string(version),
            "originator": "codex_cli_rs", "source": "cli", "thread_source": "user"
        ]
        if let childOf {
            let spawn = JSONValue.obj(["parent_thread_id": .string(childOf), "depth": .int(1)])
            meta["source"] = .obj(["subagent": .obj(["thread_spawn": spawn])])
            meta["thread_source"] = "subagent"
        }
        if version == "0.171.0" { meta["session_id"] = .string(childOf ?? id) }
        let line = JSONValue.obj(["timestamp": at, "type": "session_meta", "payload": .object(meta)])
        try (JSONEncoder().encode(line) + Data([10])).write(to: URL(fileURLWithPath: rollout(id)))
    }
    func payload(_ event: String, _ root: String, agent: String? = nil) -> [String: JSONValue] {
        var input: [String: JSONValue] = [
            "session_id": .string(root), "turn_id": "019f0004-1017-730b-9121-00a2a021c2a1",
            "transcript_path": .string(rollout(root)), "cwd": "/srv/app", "hook_event_name": .string(event),
            "model": "gpt-5.5", "permission_mode": "default"
        ]
        if event == "UserPromptSubmit" {
            input["prompt"] = .string(quoted)
            input["transcript_path"] = .string(rollout(agent ?? root))
        } else {
            input["stop_hook_active"] = .bool(false)
            input["last_assistant_message"] = .string(quoted)
            if let agent { input["agent_transcript_path"] = .string(rollout(agent)) }
        }
        if let agent {
            input["agent_id"] = .string(agent)
            input["agent_type"] = "explorer"
        }
        return input
    }

    func checkJSON(
        _ event: String, _ json: String, report: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let command = try #require(CodexHooks.hostEvents.first { $0.name == event }?.command)
        let before = try? String(contentsOf: runner.kept, encoding: .utf8)
        let frame = try runner.run(command, json)
        #expect(frame == (report.map(wrapped) ?? ""), sourceLocation: sourceLocation)
        let after = try? String(contentsOf: runner.kept, encoding: .utf8)
        #expect(
            after == (report.map { "set-option -q @kelp_status \($0)\n" } ?? before), sourceLocation: sourceLocation)
    }
    func check(
        _ event: String, _ input: [String: JSONValue], report: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(input), as: UTF8.self)
        try checkJSON(event, json, report: report, sourceLocation: sourceLocation)
    }

    // The first prompt may arrive before the rollout header. The hook still reports its state.
    let empty = UUID().uuidString.lowercased()
    try Data().write(to: URL(fileURLWithPath: rollout(empty)))
    for (event, report) in [("UserPromptSubmit", "state=working"), ("Stop", "state=done")] {
        var input = payload(event, parent)   // rollout does not exist yet
        try check(event, input, report: report)
        input["transcript_path"] = .null
        try check(event, input, report: report)
        try check(event, payload(event, empty), report: report)
    }
    try writeRollout(parent, version: "0.171.0")
    try writeRollout(child, version: "0.171.0", childOf: parent)
    try writeRollout(resumed, version: "0.129.0")
    // In 0.171 a child's prompt shares the root session_id. Its completion goes to SubagentStop.
    let childPrompt = payload("UserPromptSubmit", parent, agent: child)
    try check("UserPromptSubmit", childPrompt)
    try check("UserPromptSubmit", payload("UserPromptSubmit", parent), report: "state=working:conv=\(parent)")
    try check("Stop", payload("SubagentStop", parent, agent: child))
    try check("Stop", payload("Stop", parent), report: "state=done:conv=\(parent)")
    try check("UserPromptSubmit", payload("UserPromptSubmit", resumed), report: "state=working:conv=\(resumed)")
    try check("UserPromptSubmit", childPrompt)   // late delivery after /resume

    let oldChild = UUID().uuidString.lowercased()
    try writeRollout(oldChild, version: "0.129.0", childOf: resumed)
    for event in ["UserPromptSubmit", "Stop"] { try check(event, payload(event, oldChild)) }
    let sharedChild = UUID().uuidString.lowercased()
    try writeRollout(sharedChild, version: "0.133.0", childOf: parent)
    var unmarked = payload("UserPromptSubmit", parent)
    unmarked["transcript_path"] = .string(rollout(sharedChild))
    try check("UserPromptSubmit", unmarked)
    try check("Stop", payload("SubagentStop", parent, agent: sharedChild))
    try FileManager.default.removeItem(atPath: rollout(sharedChild))
    try check("UserPromptSubmit", unmarked)   // mismatched thread remains identifiable from its rollout name
    var invalid = payload("Stop", parent)
    invalid["session_id"] = .string("\(parent):state=working")
    try check("Stop", invalid)
    try checkJSON("Stop", #"{"session_id":"\#(parent)","hook_event_name":"Stop","last_assistant_message":"unfinished"#)
}

/// The bytes tmux sent for Claude Code's permission dialog: the options have cursor moves between them, not line ends.
@Test func aMenuFromTmuxHasItsOptionsOnLines() {
    let screen =
        "Do you want to proceed?\n ❯\n 1. Yes  2. Yes, and switch to auto mode · it handles these  3. No\n\n Esc to cancel"
    #expect(
        StartupQuestion.optionsOnLines(screen).components(separatedBy: "\n").filter { $0.contains(". ") }.map {
            $0.prefix(2)
        } == ["1.", "2.", "3."])
}

/// Codex on a host gets its hooks as they're written, through every shell on the way: the one ssh runs, the login
/// shell, tmux's for the pane and the pane's own. And the whole command still fits in one tmux message.
@Test func aHostsCodexGetsItsHooksThroughEveryShell() throws {
    let bin = tmp().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bin) }
    let got = bin.appendingPathComponent("argv")
    let scripts = [
        ("tmux", #"[ "$1" = new-session ] && exec /bin/sh -c "$5"; exit 0"#),
        ("codex", "for a in \"$@\"; do printf '%s\\n' \"$a\"; done > \(got.path)"),
        ("login", #"shift; exec /bin/sh -c "$1""#)   // the host's $SHELL -ilc, without a profile that resets PATH
    ]
    for (name, body) in scripts {
        let f = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    }
    let command = RemoteHost(host: "box", path: bin.path).command(["codex"] + CodexHooks.hostArgs, inTmux: "k")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.environment = [
        "PATH": "\(bin.path):/usr/bin:/bin", "SHELL": bin.appendingPathComponent("login").path, "HOME": bin.path
    ]
    let errors = Pipe()
    p.standardError = errors
    try p.run()
    p.waitUntilExit()
    let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let argv = try #require(try? String(contentsOf: got, encoding: .utf8), "\(said)\n\(command)")
        .split(separator: "\n", omittingEmptySubsequences: false)
    #expect(argv.dropLast().map(String.init) == CodexHooks.hostArgs)
    #expect(command.utf8.count < 16_000)
}
