import Foundation
import TestSupport
import Testing

@testable import AgentData

private func file(_ lines: [[String: Any]]) throws -> URL {
    let url = tmp().appendingPathComponent("c.jsonl")
    let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    try (text.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}
private typealias Turn = ConversationTurns.Turn

/// Claude Code's transcript: what was asked with its time, the tools between as one line, what was said.
@Test func aClaudeTranscriptReadsAsTurns() throws {
    func tool(_ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "assistant", "message": ["content": [["type": "tool_use", "name": name, "input": input]]]]
    }
    let url = try file([
        ["type": "user", "isMeta": true, "message": ["content": "<local-command-caveat>…"]],
        ["type": "user", "timestamp": "2026-11-12T05:00:00.000Z", "message": ["content": "Fix the flaky test."]],
        ["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "hm"]]]],
        tool("Grep", ["pattern": "drain"]), tool("Glob", ["pattern": "*.swift"]),
        ["type": "user", "message": ["content": [["type": "tool_result", "content": "…"]]]],
        tool("Read", ["file_path": "/p/Queue.swift"]), tool("Read", ["file_path": "/p/Queue.swift"]),
        tool("Read", ["file_path": "/p/SyncTests.swift"]), tool("TodoWrite", ["todos": []]),
        ["type": "assistant", "message": ["content": [["type": "text", "text": "The test waits on a clock."]]]],
        ["type": "assistant", "message": ["content": [["type": "text", "text": "I'll fix it."]]]],
        ["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "a subagent"]]]],
        tool("Edit", ["file_path": "/p/Tests/SyncTests.swift"]), tool("Write", ["file_path": "/p/Queue.swift"]),
        [
            "type": "user", "timestamp": "2026-11-12T05:10:00.000Z",
            "message": [
                "content": [
                    ["type": "text", "text": "<system-reminder>ignore</system-reminder>"],
                    ["type": "text", "text": "Run them."]
                ]
            ]
        ],
        tool("Bash", ["command": "swift test"]), tool("Bash", ["command": "swift test"]),
        tool("WebFetch", ["url": "x"]),
        tool("Edit", ["file_path": "/p/a.swift"])
    ])
    #expect(
        ConversationTurns.last(in: url) == [
            Turn(role: .user, text: "Fix the flaky test.", at: "2026-11-12T05:00:00.000Z"),
            Turn(role: .did, text: "Searched for 2 patterns, read 2 files"),
            Turn(role: .agent, text: "The test waits on a clock.\n\nI'll fix it."),
            Turn(role: .did, text: "Edited SyncTests.swift, Queue.swift"),
            Turn(role: .user, text: "Run them.", at: "2026-11-12T05:10:00.000Z"),
            Turn(role: .did, text: "Edited 1 file, ran 2 commands, used 1 tool")
        ])
    #expect(ConversationTurns.last(in: tmp().appendingPathComponent("none.jsonl")).isEmpty)
}

/// Codex's rollout: its own notes aren't the user's words; a script of its code mode is a command or a patch's files.
@Test func aCodexRolloutReadsAsTurns() throws {
    func message(_ role: String, _ text: String) -> [String: Any] {
        [
            "type": "response_item", "timestamp": "2026-11-12T06:00:00.000Z",
            "payload": ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
        ]
    }
    func call(_ type: String, _ name: String, _ key: String, _ sent: String) -> [String: Any] {
        ["type": "response_item", "payload": ["type": type, "name": name, key: sent]]
    }
    let url = try file([
        message("developer", "You are Codex."), message("user", "# AGENTS.md instructions"),
        message("user", "<environment_context>…</environment_context>"), message("user", "Add the export command."),
        call("function_call", "shell", "arguments", #"{"command":["bash","-lc","ls"]}"#),
        call("custom_tool_call", "exec", "input", "const r = await tools.exec_command({cmd: 'rg export'});"),
        call(
            "custom_tool_call", "exec", "input",
            #"const patch = "*** Begin Patch\n*** Update File: Sources/Export.swift\n@@\n*** Add File: Tests/E.swift\n";"#
        ),
        ["type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "CommandExecution"]]],
        message("assistant", "Both formats are easy.")
    ])
    #expect(
        ConversationTurns.last(in: url) == [
            Turn(role: .user, text: "Add the export command.", at: "2026-11-12T06:00:00.000Z"),
            Turn(role: .did, text: "Edited 2 files, ran 2 commands"),
            Turn(role: .agent, text: "Both formats are easy.")
        ])
}

/// The last turns that fit, a long one cut: what was said keeps its end, what was asked its start.
@Test func onlyTheLastTurnsThatFitAreKept() {
    let long = String(repeating: "a", count: 300) + "END"
    let turns = [
        Turn(role: .user, text: "first"), Turn(role: .agent, text: String(repeating: "b", count: 90)),
        Turn(role: .user, text: "START" + long), Turn(role: .agent, text: long)
    ]
    let kept = ConversationTurns.fitting(turns, limit: 400)   // a quarter each at most: 100
    #expect(kept.map(\.role) == [.user, .agent, .user, .agent])
    #expect(kept[2].text == "START" + String(repeating: "a", count: 95) + "…")
    #expect(kept[3].text.hasSuffix("END") && kept[3].text.hasPrefix("…") && kept[3].text.count == 101)
    let ten = (0..<10).map { Turn(role: .agent, text: "turn \($0) ten") }   // ten bytes each
    #expect(ConversationTurns.fitting(ten, limit: 45) == Array(ten.suffix(4)), "the older ones don't fit")
    #expect(ConversationTurns.fitting(turns, limit: 1 << 20) == turns)
}
