import Foundation
import Testing
@testable import AgentData
import TestSupport

@discardableResult
private func write(_ dir: URL, _ name: String, _ lines: [Any]) throws -> URL {
    let u = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    var d = Data()
    for l in lines {
        d += try (l as? String).map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: l, options: .withoutEscapingSlashes)
        d += Data("\n".utf8)
    }
    try d.write(to: u)
    return u
}

private func date(_ s: String) -> Date { JSONL.date(s) ?? .distantPast }

private func user(_ content: Any, _ ts: String, sid: String = "s1", meta: Bool = false) -> [String: Any] {
    ["type": "user", "sessionId": sid, "cwd": "/work/demo", "timestamp": ts, "isMeta": meta, "message": ["role": "user", "content": content]]
}

private func assistant(_ id: String, _ req: String, _ ts: String, model: String = "claude-opus-5-5", text: String = "ok",
                       usage: [String: Int] = ["input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40]) -> [String: Any] {
    ["type": "assistant", "sessionId": "s1", "timestamp": ts, "requestId": req,
     "message": ["id": id, "role": "assistant", "model": model, "content": [["type": "text", "text": text]], "usage": usage]]
}

@Test func claudeSessionTitles() throws {
    let root = tmp(), p = root.appendingPathComponent("-work-demo")
    let long = "  Fix the\n login   bug " + String(repeating: "a", count: 100)
    try write(p, "s1.jsonl", [
        ["type": "mode", "mode": "normal", "sessionId": "s1"],
        "not json {",
        user("<local-command-caveat>caveat</local-command-caveat>", "2026-10-18T10:00:00.000Z", meta: true),
        user("<command-name>/clear</command-name>", "2026-10-18T10:00:01.000Z"),
        user([["type": "text", "text": long]], "2026-10-18T10:00:02.000Z"),
        assistant("m1", "r1", "2026-10-18T10:00:05.000Z"),
        user([["type": "tool_result", "content": "x"]], "2026-10-18T10:05:00.000Z")
    ])
    try write(p, "s2.jsonl", [["type": "summary", "summary": "Summarized work", "leafUuid": "x"], user("hello", "2026-10-17T09:00:00Z", sid: "s2")])
    try write(p, "s3.jsonl", [
        user("first prompt", "2026-10-16T09:00:00.000Z", sid: "s3"),
        ["type": "ai-title", "aiTitle": "AI title", "sessionId": "s3"],
        ["type": "custom-title", "customTitle": "Named by hand", "sessionId": "s3"]
    ])
    try write(p, "s4.jsonl", [user("<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>ship it</command-args>",
        "2026-10-15T09:00:00Z", sid: "s4")])
    try write(p, "s1/subagents/agent-a.jsonl", [user("sub", "2026-10-18T11:00:00.000Z", sid: "s1")])
    try write(p, "empty.jsonl", [["type": "mode", "mode": "normal"]])

    let s = ClaudeHistory.sessions(root: root)
    #expect(s.map(\.id) == ["s1", "s2", "s3", "s4"])
    #expect(s[0].title.hasPrefix("Fix the login bug aaa"))
    #expect(s[0].title.count == 80 && s[0].title.hasSuffix("…"))
    #expect(s[0].cwd == "/work/demo" && s[0].agent == .claude && s[0].messageCount == 5)
    #expect(s[0].started == date("2026-10-18T10:00:00.000Z") && s[0].updated == date("2026-10-18T10:05:00.000Z"))
    #expect(s[1].title == "Summarized work")
    #expect(s[2].title == "Named by hand")
    #expect(s[3].title == "/goal ship it")
}

@Test func claudeLargeFileReadsHeadAndTail() throws {
    let root = tmp(), p = root.appendingPathComponent("-work-big")
    let pad = String(repeating: "x", count: 1000)
    var lines: [Any] = [user("big task", "2026-10-18T08:00:00.000Z")]
    for i in 0..<300 { lines.append(assistant("m\(i)", "r\(i)", "2026-10-18T09:00:00.000Z", text: pad)) }
    lines.append(assistant("last", "last", "2026-10-18T12:34:56.000Z"))
    lines.append(["type": "ai-title", "aiTitle": "Tail title", "sessionId": "s1"])
    try write(p, "s1.jsonl", lines)

    let s = try #require(ClaudeHistory.sessions(root: root).first)
    #expect(s.title == "Tail title")
    #expect(s.started == date("2026-10-18T08:00:00.000Z") && s.updated == date("2026-10-18T12:34:56.000Z"))
    #expect((200...400).contains(s.messageCount))
}

@Test func hugeLastLineIsStillRead() throws {
    let root = tmp(), p = root.appendingPathComponent("-work-huge")
    let pad = String(repeating: "x", count: 1000)
    var lines: [Any] = [user("huge task", "2026-10-18T08:00:00.000Z")]
    for i in 0..<100 { lines.append(assistant("m\(i)", "r\(i)", "2026-10-18T09:00:00.000Z", text: pad)) }
    lines.append(assistant("big", "big", "2026-10-18T12:00:00.000Z", text: String(repeating: "y", count: 300_000)))   // a big tool result
    lines.append(["type": "custom-title", "customTitle": "Named at the end", "sessionId": "s1"])
    try write(p, "s1.jsonl", lines)
    let s = try #require(ClaudeHistory.sessions(root: root).first)
    #expect(s.updated == date("2026-10-18T12:00:00.000Z"))
    #expect(s.title == "Named at the end")
}

@Test func usageIndexDedupesAcrossReads() throws {
    let root = tmp(), p = root.appendingPathComponent("-work-demo")
    let now = ISO8601DateFormatter().string(from: Date())
    let f = try write(p, "s1.jsonl", [assistant("m1", "r1", now), assistant("m1", "r1", now), assistant("m2", "r2", now, model: "<synthetic>")])
    try write(p, "s1/subagents/agent-a.jsonl", [assistant("m3", "r3", now)])
    let idx = UsageIndex(cache: root.appendingPathComponent("cache.json"))
    let since = Date().addingTimeInterval(-86400)
    func output() -> Int { idx.rows(roots: [root], since: since).reduce(0) { $0 + $1.tally.tokens.output } }
    #expect(output() == 40)
    // The same response's next line lands after that read: still one response.
    let h = try FileHandle(forWritingTo: f); try h.seekToEnd()
    try h.write(contentsOf: JSONSerialization.data(withJSONObject: assistant("m1", "r1", now)) + Data("\n".utf8)); try h.close()
    #expect(output() == 40)
    #expect(idx.currentBlock(roots: [root])?.tokens.output == 40)
}

@Test func fiveHourBlocks() throws {
    let t = UsageIndex.Tally(tokens: TokenCounts(input: 1_000_000), cost: 4)
    func h(_ s: String, _ m: String = "claude-opus-5-5") -> UsageIndex.Hour { .init(start: date(s), model: m, tally: t) }
    let hours = [h("2026-10-18T10:00:00Z", "claude-sonnet-5-5"), h("2026-10-18T11:00:00Z"), h("2026-10-18T14:00:00Z"),
                 h("2026-10-18T15:00:00Z"), h("2026-10-18T22:00:00Z")]
    let first = try #require(UsageIndex.block(hours, now: date("2026-10-18T14:45:00Z")))
    #expect(first.start == date("2026-10-18T10:00:00Z") && first.end == date("2026-10-18T15:00:00Z") && first.tokens.input == 3_000_000)
    #expect(first.models == ["claude-opus-5-5", "claude-sonnet-5-5"] && first.estimatedCostUSD == 12)
    let b = try #require(UsageIndex.block(hours, now: date("2026-10-18T16:00:00Z")))
    #expect(b.start == date("2026-10-18T15:00:00Z") && b.end == date("2026-10-18T20:00:00Z") && b.tokens.input == 1_000_000)
    #expect(UsageIndex.block(hours, now: date("2026-10-18T21:00:00Z")) == nil)
    #expect(UsageIndex.block(hours, now: date("2026-10-18T22:30:00Z"))?.end == date("2026-10-19T03:00:00Z"))
}

@Test func pricingMath() {
    let m = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
    #expect(abs(Pricing.cost(model: "claude-opus-5-5", tokens: m) - 29.2) < 1e-9)
    #expect(abs(Pricing.cost(model: "claude-opus-5-5[1m]", tokens: TokenCounts(input: 500, output: 100)) - 0.004) < 1e-12)
    #expect(Pricing.cost(model: "claude-opus-4-8", tokens: TokenCounts(input: 1_000_000)) == 5)
    #expect(Pricing.cost(model: "claude-sonnet-4-6", tokens: TokenCounts(input: 1_000_000)) == 3)
    #expect(Pricing.cost(model: "claude-sonnet-5-5", tokens: TokenCounts(input: 1_000_000)) == 2)
    #expect(Pricing.cost(model: "claude-fable-5-1", tokens: TokenCounts(cacheRead: 1_000_000)) == 0.25)
    #expect(Pricing.cost(model: "claude-fable-5", tokens: TokenCounts(cacheRead: 1_000_000)) == 1)
    #expect(Pricing.cost(model: "claude-haiku-4-5", tokens: TokenCounts(input: 1_000_000)) == 1)
    #expect(Pricing.cost(model: "gpt-5.1-codex-mini", tokens: TokenCounts(input: 1_000_000)) == 0.25)
    #expect(Pricing.cost(model: "gpt-5.2-codex", tokens: TokenCounts(output: 1_000_000)) == 14)
    #expect(Pricing.cost(model: "gpt-5.5", tokens: TokenCounts(input: 1_000_000)) == 1.25)
    #expect(Pricing.cost(model: "llama-3", tokens: m) == 0)
}

@Test func codexSessionsAndLimits() throws {
    let root = tmp()
    let id1 = "019f47f3-8f9b-7823-98a3-9195ae68d901", id2 = "019f47f3-8f9b-7823-98a3-9195ae68d902"
    func item(_ role: String, _ text: String, _ ts: String) -> [String: Any] {
        ["timestamp": ts, "type": "response_item", "payload": ["type": "message", "role": role, "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]]
    }
    func tokens(_ ts: String, _ rl: Any) -> [String: Any] {
        ["timestamp": ts, "type": "event_msg", "payload": ["type": "token_count", "info": NSNull(), "rate_limits": rl]]
    }
    let f1 = try write(root, "2026/10/17/rollout-2026-10-17T10-00-00-\(id1).jsonl", [
        ["timestamp": "2026-10-17T10:00:00.100Z", "type": "session_meta", "payload": ["id": id1, "cwd": "/work/a", "timestamp": "2026-10-17T10:00:00.000Z"]],
        item("user", "# AGENTS.md instructions for /work/a", "2026-10-17T10:00:01.000Z"),
        item("user", "<environment_context><cwd>/work/a</cwd></environment_context>", "2026-10-17T10:00:01.000Z"),
        ["timestamp": "2026-10-17T10:00:02.000Z", "type": "event_msg", "payload": ["type": "user_message", "message": "Refactor the parser"]],
        item("user", "Refactor the parser", "2026-10-17T10:00:02.000Z"),
        item("assistant", "Done", "2026-10-17T10:01:00.000Z"),
        tokens("2026-10-17T10:01:00.000Z", ["primary": ["used_percent": 12.5, "window_minutes": 300, "resets_at": 1_792_000_000],
                                             "secondary": ["used_percent": 40, "window_minutes": 10080, "resets_at": 1_792_500_000]]),
        tokens("2026-10-17T10:02:00.000Z", ["primary": NSNull(), "secondary": NSNull(), "credits": NSNull()])
    ])
    try write(root, "2026/10/18/rollout-2026-10-18T09-00-00-\(id2).jsonl", [
        ["timestamp": "2026-10-18T09:00:00.000Z", "type": "session_meta", "payload": ["id": id2, "cwd": "/work/b", "timestamp": "2026-10-18T09:00:00.000Z"]],
        item("user", "Old shape please", "2026-10-18T09:00:01.000Z"),
        tokens("2026-10-18T09:05:00.000Z", ["primary": ["used_percent": 50, "window_minutes": 300, "resets_in_seconds": 600]])
    ])

    let s = CodexHistory.sessions(root: root)
    #expect(s.map(\.id) == [id2, id1])
    #expect(s[1].title == "Refactor the parser" && s[1].cwd == "/work/a" && s[1].messageCount == 4 && s[1].agent == .codex)
    #expect(s[0].title == "Old shape please")

    let l1 = try #require(CodexUsage.latest(in: f1))
    #expect(l1 == CodexLimits(primaryUsedPercent: 12.5, primaryResetsAt: Date(timeIntervalSince1970: 1_792_000_000),
                              secondaryUsedPercent: 40, secondaryResetsAt: Date(timeIntervalSince1970: 1_792_500_000),
                              observedAt: date("2026-10-17T10:01:00.000Z")))
    let l = try #require(CodexUsage.latest(root: root))
    #expect(l.observedAt == date("2026-10-18T09:05:00.000Z") && l.primaryUsedPercent == 50)
    #expect(l.primaryResetsAt == date("2026-10-18T09:15:00.000Z") && l.secondaryUsedPercent == nil)

    let flat = CodexUsage.limits(tokens("2026-10-18T09:05:00Z", ["primary_used_percent": 7, "secondary_used_percent": 3]))
    #expect(flat?.primaryUsedPercent == 7 && flat?.secondaryUsedPercent == 3)

    // Conversations Codex Desktop imported from Claude Code: newer than the real ones, and without limits.
    for i in 0..<12 {
        let f = try write(root, "2026/10/20/rollout-2026-10-20T00-00-00-imported-\(i).jsonl", [tokens("2026-10-20T00:00:00.000Z", NSNull())])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.path)
    }
    #expect(CodexUsage.latest(root: root)?.primaryUsedPercent == 50)
}

@Test func searchAndResume() throws {
    let root = tmp(), p = root.appendingPathComponent("-work-demo")
    try write(p, "a.jsonl", [user("deploy the app", "2026-10-18T10:00:00Z", sid: "a"), assistant("m1", "r1", "2026-10-18T10:01:00Z", text: "the flux capacitor is fine")])
    try write(p, "b.jsonl", [user("write docs", "2026-10-18T11:00:00Z", sid: "b"), assistant("m2", "r2", "2026-10-18T11:01:00Z", text: "nothing here")])
    let s = ClaudeHistory.sessions(root: root)
    #expect(History.search(s, query: "DEPLOY").map(\.id) == ["a"])
    #expect(History.search(s, query: "/work/demo").count == 2)
    #expect(History.search(s, query: " ").count == 2)
    #expect(History.fullTextSearch(query: "Flux Capacitor", in: s).map(\.id) == ["a"])
    #expect(History.fullTextSearch(query: "the", in: s, limit: 1).count == 1)
    #expect(History.fullTextSearch(query: "", in: s).isEmpty)

    #expect(History.resumeCommand(for: s[0]) == ["claude", "--resume", s[0].id])
    var codex = s[0]
    codex.agent = .codex
    #expect(History.resumeCommand(for: codex) == ["codex", "resume", s[0].id])
}

@Test func missingDirsAreEmpty() {
    let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(ClaudeHistory.sessions(root: nowhere).isEmpty)
    #expect(CodexHistory.sessions(root: nowhere).isEmpty)
    #expect(UsageIndex(cache: nowhere.appendingPathComponent("c.json")).rows(roots: [nowhere], since: .distantPast).isEmpty)
    #expect(CodexUsage.latest(root: nowhere) == nil)
}

@Test func claudeSessionsForOneFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dir = root.appendingPathComponent("-work-my-app")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let line = #"{"type":"user","sessionId":"abc","cwd":"/work/my_app","timestamp":"2026-10-19T00:00:00Z","message":{"content":"hi"}}"#
    try Data((line + "\n").utf8).write(to: dir.appendingPathComponent("abc.jsonl"))
    #expect(ClaudeHistory.sessions(cwd: "/work/my_app", root: root).map(\.id) == ["abc"])
    #expect(ClaudeHistory.sessions(cwd: "/work/other", root: root).isEmpty)
    // One by id, as waking a pinned session asks: found in any case, not in another folder, not when never written.
    #expect(ClaudeHistory.session(id: "ABC", cwd: "/work/my_app", root: root)?.id == "abc")
    #expect(ClaudeHistory.session(id: "abc", cwd: "/work/other", root: root) == nil)
    #expect(ClaudeHistory.session(id: "nope", cwd: "/work/my_app", root: root) == nil)
}

@Test func usageIndexReadsOnlyWhatsNew() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("s.jsonl")
    func line(_ id: String, _ ts: String, _ out: Int) -> String {
        #"{"parentUuid":null,"cwd":"/p","message":{"id":"\#(id)","type":"message","role":"assistant","model":"claude-sonnet-4-5","#
            + #""content":[{"type":"text","text":"{ not usage }"}],"usage":{"input_tokens":10,"output_tokens":\#(out),"#
            + #""cache_creation":{"ephemeral_5m_input_tokens":0}}},"requestId":"r\#(id)","type":"assistant","timestamp":"\#(ts)"}"#
    }
    let now = ISO8601DateFormatter().string(from: Date())
    let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86400))   // copied in by a resume: before the file existed
    try [line("a", now, 5), line("a", now, 5), line("b", old, 100)].joined(separator: "\n").appending("\n").write(to: f, atomically: true, encoding: .utf8)
    let idx = UsageIndex(cache: dir.appendingPathComponent("cache.json"))
    let since = Date().addingTimeInterval(-7 * 86400)
    #expect(idx.rows(roots: [dir], since: since).reduce(0) { $0 + $1.tally.tokens.output } == 5)
    let h = try FileHandle(forWritingTo: f); try h.seekToEnd(); try h.write(contentsOf: Data((line("c", now, 7) + "\n").utf8)); try h.close()
    let again = UsageIndex(cache: dir.appendingPathComponent("cache.json"))   // from disk: the old part isn't read again
    let rows = again.rows(roots: [dir], since: since)
    #expect(rows.reduce(0) { $0 + $1.tally.tokens.output } == 12)
    #expect(rows.first?.cwd == "/p" && rows.first?.model == "claude-sonnet-4-5")
    // Read in 8 MB pieces from where the last read ended: a long line (a pasted image) puts the next one's end, usage
    // and all, past the first piece.
    let d = line("d", now, 30), g = try FileHandle(forWritingTo: f); try g.seekToEnd()
    try g.write(contentsOf: Data((#"{"type":"user","text":""# + String(repeating: "x", count: (8 << 20) - 26 - d.utf8.count + 120) + "\"}\n" + d + "\n").utf8)); try g.close()
    #expect(UsageIndex(cache: dir.appendingPathComponent("cache.json")).rows(roots: [dir], since: since).reduce(0) { $0 + $1.tally.tokens.output } == 42)
}

@Test func timesAndDaysReadTheWayTranscriptsWriteThem() throws {
    let a = try #require(JSONL.date("2026-10-20T10:15:30.250Z")?.timeIntervalSince1970), b = try #require(JSONL.date("2026-10-20T10:15:30Z")?.timeIntervalSince1970)
    #expect(abs(a - b - 0.25) < 0.001)   // with and without fractional seconds
    #expect(JSONL.date("not a time") == nil)
    var c = Calendar.current; c.timeZone = .current
    let noon = try #require(c.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
    #expect(UsageIndex.day(noon) == "2026-03-07")   // the local day, zero-padded
}

/// What fills the context: since the last /compact, by part (Read by file, Bash by command, the conversation), scaled to
/// the tokens the last reply counted on top of the first request's base.
@Test func contextPartsSinceTheLastCompaction() throws {
    func line(_ o: [String: Any]) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self) }
    func reply(_ input: Int, _ blocks: [[String: Any]]) -> String {
        line(["type": "assistant", "message": ["content": blocks, "usage": ["input_tokens": input]]])
    }
    func results(_ r: [(String, String)]) -> String {
        line(["type": "user", "message": ["content": r.map { ["type": "tool_result", "tool_use_id": $0.0, "content": $0.1] }]])
    }
    let old = [line(["type": "user", "message": ["content": String(repeating: "x", count: 400)]]), reply(1100, [["type": "text", "text": "hi"]]),
               results([("gone", String(repeating: "g", count: 9000))])]
    let now = [
        line(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["preTokens": 9000, "postTokens": 300]]),
        line(["type": "user", "isCompactSummary": true, "message": ["content": String(repeating: "s", count: 400)]]),
        reply(1200, [["type": "tool_use", "id": "r1", "name": "Read", "input": ["file_path": "/a/payment.ts"]],
                     ["type": "tool_use", "id": "b1", "name": "Bash", "input": ["command": "cd app && npm test -- --ci"]],
                     ["type": "tool_use", "id": "b2", "name": "Bash", "input": ["command": "npm test"]]]),
        results([("r1", String(repeating: "f", count: 2000)), ("b1", String(repeating: "t", count: 1000)), ("b2", String(repeating: "t", count: 1000))]),
        line(["type": "attachment", "rendered": [["content": String(repeating: "n", count: 200)]]]),
        line(["type": "user", "isSidechain": true, "message": ["content": String(repeating: "z", count: 8000)]]),   // a subagent's
        reply(2400, [["type": "text", "text": "Done"]])
    ]
    let data = Data((old + now).joined(separator: "\n").utf8)
    let p = try #require(ClaudeContext.parts(data, used: 2400))
    #expect(p.base == 1000)   // the first request, less what was typed (400 / 4)
    #expect(p.parts.map(\.kind) == [.files, .commands, .conversation, .summary])
    let files = try #require(p.parts.first), cmds = p.parts[1]
    #expect(files.top.map(\.label) == ["payment.ts"])
    #expect(cmds.top.map(\.label) == ["npm test"] && cmds.top[0].count == 2)   // both runs, under one name
    #expect(files.tokens == cmds.tokens)   // 2000 characters each
    let sum = p.base + p.parts.reduce(0) { $0 + $1.tokens }
    #expect((2390...2400).contains(sum))   // scaled to what the reply counted
    #expect(ClaudeContext.parts(Data(old.joined(separator: "\n").utf8), used: 0) == nil)
}
