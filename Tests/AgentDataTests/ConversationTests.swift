import Foundation
import TestSupport
import Testing

@testable import AgentData

@Test func lastReplyFromTranscript() throws {
    let f = tmp().appendingPathComponent("t.jsonl")
    let lines = [
        #"{"type":"user","message":{"content":"hi"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"First answer."}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed the parser tests."}]}}"#,
        #"{"type":"system","subtype":"stop"}"#
    ]
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    #expect(ClaudeHistory.lastReply(transcript: f) == "Fixed the parser tests.")
}

/// The context ring reads the last real reply, skips subagents and API errors, and drops to what a compaction left.
@Test func contextUsageFromTranscript() throws {
    let f = tmp().appendingPathComponent("t.jsonl")
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    func write(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    }
    let reply =
        #"{"type":"assistant","message":{"model":"m","usage":{"input_tokens":2,"cache_read_input_tokens":250000,"cache_creation_input_tokens":8,"output_tokens":90}}}"#
    try write([
        reply,
        #"{"type":"assistant","isSidechain":true,"message":{"model":"m","usage":{"input_tokens":5}}}"#,
        #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
    ])
    let c = try #require(ClaudeContext.usage(transcript: f))
    #expect(c.used == 250_010 && c.peak == 250_010 && c.model == "m")   // the reply's output isn't counted, as in Claude Code
    try write([
        reply,
        #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"preTokens":260000,"postTokens":40000}}"#
    ])
    let after = try #require(ClaudeContext.usage(transcript: f))
    #expect(after.used == 40_000 && after.peak == 260_000 && after.model == "m")
}

/// A hand-off brief is the conversation itself: what was asked and answered, not tool output; one side's blocks are one turn.
@Test func handoffBriefFromTranscript() throws {
    let u = tmp().appendingPathComponent("t.jsonl")
    let lines = [
        #"{"type":"user","message":{"role":"user","content":"Add a login page"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll add it."},{"type":"tool_use","name":"Write"}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
        #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done: login.html"}]}}"#
    ]
    try lines.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
    let brief = try #require(Conversation(file: u)).markdown(limit: 10_000)
    #expect(brief == "## You\n\nAdd a login page\n\n## Agent\n\nI'll add it.\n\nDone: login.html")
}

/// Codex's rollout and pi's session read the same way: only what was said, not injected context or tool calls.
@Test func handoffBriefFromCodexAndPi() throws {
    let codex = tmp().appendingPathComponent("rollout.jsonl"), pi = tmp().appendingPathComponent("pi.jsonl")
    try [
        #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
        ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the build"}]}}"#,
        #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
        #"{"type":"event_msg","payload":{"type":"agent_message","message":"Fixed"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed"}]}}"#
    ].joined(separator: "\n").write(to: codex, atomically: true, encoding: .utf8)
    try [
        #"{"type":"session","cwd":"/tmp"}"#,
        #"{"type":"message","message":{"role":"system","content":"prompt"}}"#,
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Fix the build"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"toolCall","name":"bash"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Fixed"}]}}"#
    ].joined(separator: "\n").write(to: pi, atomically: true, encoding: .utf8)
    for file in [codex, pi] {
        #expect(Conversation(file: file)?.markdown(limit: 10_000) == "## You\n\nFix the build\n\n## Agent\n\nFixed")
    }
}

/// Beside the words: the files each agent changed, the commands it ran (each once, latest last) and its last plan.
@Test func handoffNotesFromToolCalls() throws {
    let claude = tmp().appendingPathComponent("c.jsonl"), codex = tmp().appendingPathComponent("x.jsonl")
    let pi = tmp().appendingPathComponent("p.jsonl")
    try [
        #"{"type":"user","message":{"content":"Go"}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/p/a.swift"}},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}},{"type":"tool_use","name":"Write","input":{"file_path":"/p/b.swift"}},{"type":"tool_use","name":"Bash","input":{"command":"ls"}},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}},{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Edit","status":"completed"},{"content":"Test","status":"in_progress"},{"content":"Ship","status":"pending"}]}}]}}"#
    ].joined(separator: "\n").write(to: claude, atomically: true, encoding: .utf8)
    try [
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Go"}]}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Edit\",\"status\":\"completed\"}]}"}}"#,
        #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","make"],"parsed_cmd":[{"type":"unknown","cmd":"make"}]}}}"#,
        #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","changes":{"/p/b.swift":{},"/p/a.swift":{}}}}}"#
    ].joined(separator: "\n").write(to: codex, atomically: true, encoding: .utf8)
    try [
        #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Go"}]}}"#,
        #"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"edit","arguments":{"path":"/p/a.swift"}},{"type":"toolCall","name":"bash","arguments":{"command":"make"}}]}}"#
    ].joined(separator: "\n").write(to: pi, atomically: true, encoding: .utf8)
    let c = try #require(Conversation(file: claude)), x = try #require(Conversation(file: codex))
    let p = try #require(Conversation(file: pi))
    #expect(c.changed == ["/p/a.swift", "/p/b.swift"] && c.commands == ["ls", "swift test"])
    #expect(c.plan == ["[x] Edit", "[~] Test", "[ ] Ship"])
    #expect(x.changed == ["/p/a.swift", "/p/b.swift"] && x.commands == ["make"] && x.plan == ["[x] Edit"])
    #expect(p.changed == ["/p/a.swift"] && p.commands == ["make"])
    let brief = c.markdown(limit: 10_000, uncommitted: " M a.swift")
    #expect(
        brief.hasPrefix("## Its plan\n\n[x] Edit")
            && brief.contains("## Files it changed\n\n- /p/a.swift\n- /p/b.swift"))
    #expect(
        brief.contains("- `swift test`") && brief.contains("```\n M a.swift\n```") && brief.hasSuffix("## You\n\nGo"))
}

/// Cut to its limit, a brief still starts with the task: the first turn, then the newest, "…" for what's between.
@Test func handoffBriefKeepsTheTask() throws {
    var talk = Conversation()
    talk.turns =
        [.init(user: true, text: "THE TASK")]
        + (1...50).map { .init(user: $0 % 2 == 0, text: "turn \($0) " + String(repeating: "x", count: 90)) }
    let kept = talk.kept(limit: 400)
    #expect(kept.first?.text == "THE TASK" && kept.last == talk.turns.last && kept.count < talk.turns.count)
    #expect(kept.map(\.text.count).reduce(0, +) <= 400 + kept.count)
    #expect(talk.markdown(limit: 400).hasPrefix("## You\n\nTHE TASK\n\n…\n\n## "))
}

/// The pi session a hand-off writes: a header, then one message per turn each the child of the one before, the
/// answers as another program's, and the notes last as a message the model reads.
@Test func handoffPiSession() throws {
    var talk = Conversation()
    talk.turns = [.init(user: true, text: "Add login"), .init(user: false, text: "Done")]
    talk.changed = ["/p/login.html"]
    let lines = try talk.piSession(cwd: "/p", agent: "claude", limit: 10_000, uncommitted: "")
        .split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    #expect(lines.map { $0["type"] as? String } == ["session", "message", "message", "custom_message"])
    #expect(lines[0]["version"] as? Int == 3 && lines[0]["cwd"] as? String == "/p")
    #expect(lines[1]["parentId"] is NSNull && lines[2]["parentId"] as? String == lines[1]["id"] as? String)
    #expect(lines[3]["parentId"] as? String == lines[2]["id"] as? String)
    let answer = try #require(lines[2]["message"] as? [String: Any])
    #expect(answer["role"] as? String == "assistant" && answer["provider"] as? String == "claude")
    #expect(answer["usage"] != nil && answer["stopReason"] as? String == "stop")
    #expect((lines[3]["content"] as? String)?.contains("- /p/login.html") == true)
}
