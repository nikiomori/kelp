import Foundation
import TestSupport
import Testing

@testable import AgentData

@discardableResult
private func write(_ dir: URL, _ name: String, _ lines: [Any]) throws -> URL {
    let u = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    var d = Data()
    for l in lines {
        d +=
            try (l as? String).map { Data($0.utf8) }
            ?? JSONSerialization.data(withJSONObject: l, options: .withoutEscapingSlashes)
        d += Data("\n".utf8)
    }
    try d.write(to: u)
    return u
}

private func date(_ s: String) -> Date { JSONL.date(s) ?? .distantPast }

private func user(_ content: Any, _ ts: String, sid: String = "s1", meta: Bool = false) -> [String: Any] {
    [
        "type": "user", "sessionId": sid, "cwd": "/work/demo", "timestamp": ts, "isMeta": meta,
        "message": ["role": "user", "content": content]
    ]
}

private func assistant(
    _ id: String, _ req: String, _ ts: String, model: String = "claude-opus-5-5", text: String = "ok",
    usage: [String: Int] = [
        "input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40
    ]
) -> [String: Any] {
    [
        "type": "assistant", "sessionId": "s1", "timestamp": ts, "requestId": req,
        "message": [
            "id": id, "role": "assistant", "model": model, "content": [["type": "text", "text": text]], "usage": usage
        ]
    ]
}

@Test func claudeSessionTitles() throws {
    let root = tmp(), p = root.appendingPathComponent("-work-demo")
    let long = "  Fix the\n login   bug " + String(repeating: "a", count: 100)
    try write(
        p, "s1.jsonl",
        [
            ["type": "mode", "mode": "normal", "sessionId": "s1"],
            "not json {",
            user("<local-command-caveat>caveat</local-command-caveat>", "2026-10-18T10:00:00.000Z", meta: true),
            user("<command-name>/clear</command-name>", "2026-10-18T10:00:01.000Z"),
            user([["type": "text", "text": long]], "2026-10-18T10:00:02.000Z"),
            assistant("m1", "r1", "2026-10-18T10:00:05.000Z"),
            user([["type": "tool_result", "content": "x"]], "2026-10-18T10:05:00.000Z")
        ])
    try write(
        p, "s2.jsonl",
        [
            ["type": "summary", "summary": "Summarized work", "leafUuid": "x"],
            user("hello", "2026-10-17T09:00:00Z", sid: "s2")
        ])
    try write(
        p, "s3.jsonl",
        [
            user("first prompt", "2026-10-16T09:00:00.000Z", sid: "s3"),
            ["type": "ai-title", "aiTitle": "AI title", "sessionId": "s3"],
            ["type": "custom-title", "customTitle": "Named by hand", "sessionId": "s3"]
        ])
    try write(
        p, "s4.jsonl",
        [
            user(
                "<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>ship it</command-args>",
                "2026-10-15T09:00:00Z", sid: "s4")
        ])
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

@Test func codexMarkupPromptsReachTurnsTitlesAndWorkLogs() throws {
    let at = "2026-11-24T12:00:00.000Z", id = "019f47f3-8f9b-7823-98a3-9195ae68d901"
    func message(_ blocks: String...) -> [String: Any] {
        [
            "timestamp": at, "type": "response_item",
            "payload": ["type": "message", "role": "user", "content": blocks.map { ["type": "input_text", "text": $0] }]
        ]
    }
    func event(_ text: String) -> [String: Any] {
        [
            "timestamp": at, "type": "event_msg",
            "payload": ["type": "user_message", "message": text, "images": [], "text_elements": []]
        ]
    }
    let root = tmp(), context = "<environment_context>\n<cwd>/work/demo</cwd>\n</environment_context>"
    let notice = "<subagent_notification>\n{\"status\":\"completed\"}\n</subagent_notification>"
    let services = [
        ["timestamp": at, "type": "session_meta", "payload": ["id": id, "cwd": "/work/demo"]],
        message("# AGENTS.md instructions for /work/demo", context), message(notice), event(notice)
    ]
    let html = "<button disabled>Save</button> should be enabled."
    let xml = "<?xml version=\"1.0\"?>\n<feed/>", angle = "< 5 ms is the target."
    let xmlWithContext = context + "\n\n" + xml
    let paired = [
        message(context, html, notice), event(html),
        message(xmlWithContext), event(xmlWithContext),
        message(angle), event(angle)
    ]
    for (lines, title, turns, prompts) in [
        ([], "", [], []),
        ([event(html)], html, [], [html]),
        ([message(context, html)], html, [html], []),
        (paired, html, [html, xml, angle], [html, xml, angle])
    ] {
        let url = try write(root, "2026/11/24/rollout-2026-11-24T12-00-00-\(id).jsonl", services + lines)
        #expect(CodexHistory.sessions(root: root).first?.title == title)
        #expect(ConversationTurns.last(in: url).map(\.text) == turns)
        var work = WorkLog()
        work.read(try Data(contentsOf: url))
        #expect(work.prompts.map(\.text) == prompts)
    }
}

@Test func claudeLastPromptTitleSkipsServiceMessages() throws {
    let root = tmp(), notice = "<local-command-stdout>Nothing to clear</local-command-stdout>"
    let service: [Any] = [
        user(notice, "2026-10-18T10:00:00Z"), ["type": "last-prompt", "lastPrompt": notice]
    ]
    let markup = "<title>Dashboard</title>"
    let onlyService = try write(root, "empty.jsonl", service)
    #expect(ClaudeHistory.parse(onlyService)?.title == "")
    let withMarkup = try write(root, "markup.jsonl", service + [["type": "last-prompt", "lastPrompt": markup]])
    #expect(ClaudeHistory.parse(withMarkup)?.title == markup)
}

@Test func generatedPromptTagsMatchWholeNames() {
    for markup in ["<system-reminder-example/>", "<command-line>make</command-line>", "<3", "<div><skill/></div>"] {
        #expect(JSONL.typed(markup) == markup)
    }
    for service in [
        "<system-reminder>one</system-reminder>\n<local-command-stdout>two</local-command-stdout>",
        "<turn_aborted>user interrupted the turn</turn_aborted>", "[Request interrupted by user]",
        "<kelp from=\"reviewer abc12345\" status=\"done\">review</kelp>",
        "<command-name>/clear</command-name>\n<command-args></command-args>"
    ] {
        #expect(JSONL.typed(service) == nil)
    }
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
    let f = try write(
        p, "s1.jsonl",
        [assistant("m1", "r1", now), assistant("m1", "r1", now), assistant("m2", "r2", now, model: "<synthetic>")])
    try write(p, "s1/subagents/agent-a.jsonl", [assistant("m3", "r3", now)])
    let idx = UsageIndex(cache: root.appendingPathComponent("cache.json"))
    let since = Date().addingTimeInterval(-86400)
    func output() -> Int { idx.rows(roots: [root], since: since).reduce(0) { $0 + $1.tally.tokens.output } }
    #expect(output() == 40)
    // The same response's next line lands after that read: still one response.
    let h = try FileHandle(forWritingTo: f)
    try h.seekToEnd()
    try h.write(contentsOf: JSONSerialization.data(withJSONObject: assistant("m1", "r1", now)) + Data("\n".utf8))
    try h.close()
    #expect(output() == 40)
    #expect(idx.currentBlock(roots: [root])?.tokens.output == 40)
}

@Test func fiveHourBlocks() throws {
    let t = UsageIndex.Tally(tokens: TokenCounts(input: 1_000_000), cost: 4)
    func h(_ s: String, _ m: String = "claude-opus-5-5") -> UsageIndex.Hour {
        .init(start: date(s), model: m, tally: t)
    }
    let hours = [
        h("2026-10-18T10:00:00Z", "claude-sonnet-5-5"), h("2026-10-18T11:00:00Z"), h("2026-10-18T14:00:00Z"),
        h("2026-10-18T15:00:00Z"), h("2026-10-18T22:00:00Z")
    ]
    let first = try #require(UsageIndex.block(hours, now: date("2026-10-18T14:45:00Z")))
    #expect(
        first.start == date("2026-10-18T10:00:00Z") && first.end == date("2026-10-18T15:00:00Z")
            && first.tokens.input == 3_000_000)
    #expect(first.models == ["claude-opus-5-5", "claude-sonnet-5-5"] && first.estimatedCostUSD == 12)
    let b = try #require(UsageIndex.block(hours, now: date("2026-10-18T16:00:00Z")))
    #expect(
        b.start == date("2026-10-18T15:00:00Z") && b.end == date("2026-10-18T20:00:00Z") && b.tokens.input == 1_000_000)
    #expect(UsageIndex.block(hours, now: date("2026-10-18T21:00:00Z")) == nil)
    #expect(UsageIndex.block(hours, now: date("2026-10-18T22:30:00Z"))?.end == date("2026-10-19T03:00:00Z"))
}

/// A model id finds its price by family, the specific ids before their fallback (Fable 5.1's cheaper cache reads, Opus
/// 5.5's own rates, "[1m]" the same model); a model with none (a router path, an open model) costs nothing.
@Test func aModelIdFindsItsPrice() {
    func row(_ match: String) -> Pricing? { Pricing.table.first { $0.match == match }?.price }
    let rows: [(String, String?)] = [
        ("claude-opus-5-5", "opus-5-5"), ("claude-opus-5-5[1m]", "opus-5-5"), ("claude-opus-4-8", "opus"),
        ("claude-sonnet-5-5", "sonnet-5-5"), ("claude-sonnet-5", "sonnet"), ("claude-sonnet-4-6", "sonnet-4"),
        ("claude-fable-5-1", "fable-5-1"), ("claude-fable-5", "fable"), ("claude-haiku-5-5", "haiku-5"),
        ("claude-haiku-4-5", "haiku"), ("gpt-5.1-codex-mini", "-mini"), ("gpt-5.2-codex", "gpt-5.2"),
        ("gpt-5.5", "gpt-5"), ("gpt-5.6-terra", "gpt-5.6-terra"), ("gpt-6-luna", "gpt-6-luna"),
        ("openrouter/free", nil), ("llama-3", nil)
    ]
    for (model, match) in rows { #expect(Pricing.of(model) == match.flatMap(row), "\(model)") }
    let m = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
    #expect(Pricing.cost(model: "llama-3", tokens: m) == 0)
}

/// A call costs its tokens at its model's rates, per million. A cache write kept for an hour costs twice the input
/// rate, not the five-minute rate; past Haiku 5.5's long prompt (the cache counted in it) every rate is five times.
@Test func pricingMath() throws {
    let opus = try #require(Pricing.of("claude-opus-5-5"))
    let m = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
    #expect(
        abs(
            Pricing.cost(model: "claude-opus-5-5", tokens: m)
                - (opus.input + opus.output + opus.cacheWrite + opus.cacheRead)) < 1e-9)
    let write = TokenCounts(cacheWrite: 1_000_000)
    #expect(Pricing.cost(model: "claude-opus-5-5", tokens: write) == opus.cacheWrite)
    #expect(Pricing.cost(model: "claude-opus-5-5", tokens: write, hourWrites: 1_000_000) == 2 * opus.input)
    let haiku = try #require(Pricing.of("claude-haiku-5-5"))
    let long = TokenCounts(output: 1000, cacheRead: haiku.longPrompt + 1)
    #expect(abs(Pricing.cost(model: "claude-haiku-5-5", tokens: long) - 5 * haiku.cost(long)) < 1e-12)
    let atLimit = TokenCounts(output: 1000, cacheRead: haiku.longPrompt)
    #expect(abs(Pricing.cost(model: "claude-haiku-5-5", tokens: atLimit) - haiku.cost(atLimit)) < 1e-12)
}

@Test func aCodexChatsLastReplyIsItsFolders() throws {
    let root = tmp().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let start = Date(), f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy/MM/dd"
    let day = root.appendingPathComponent(f.string(from: start))
    f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    func rollout(after seconds: TimeInterval, cwd: String, replies: [String?]) throws {
        func line(_ o: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        }
        let meta: [String: Any] = ["id": UUID().uuidString, "cwd": cwd]
        var lines = [try line(["type": "session_meta", "payload": meta])]
        for r in replies {
            let said: Any = r ?? NSNull()
            let payload: [String: Any] = ["type": "task_complete", "last_agent_message": said]
            lines.append(try line(["type": "event_msg", "payload": payload]))
        }
        let name = "rollout-\(f.string(from: start.addingTimeInterval(seconds)))-\(UUID().uuidString).jsonl"
        try lines.joined(separator: "\n").write(to: day.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try rollout(after: -5, cwd: "/work/a", replies: ["from before it started"])
    try rollout(after: 0, cwd: "/work/a", replies: ["first", "second"])
    try rollout(after: 1, cwd: "/work/b", replies: ["another folder"])
    #expect(CodexHistory.lastReply(cwd: "/work/a", since: start, root: root) == "second")
    try rollout(after: 2, cwd: "/work/a", replies: [nil])
    #expect(
        CodexHistory.lastReply(cwd: "/work/a", since: start, root: root) == "second", "a turn cut short says nothing")
    #expect(CodexHistory.lastReply(cwd: "/work/none", since: start, root: root) == nil)
}

@Test func codexSessionsAndLimits() throws {
    let root = tmp()
    let id1 = "019f47f3-8f9b-7823-98a3-9195ae68d901", id2 = "019f47f3-8f9b-7823-98a3-9195ae68d902"
    func item(_ role: String, _ text: String, _ ts: String) -> [String: Any] {
        [
            "timestamp": ts, "type": "response_item",
            "payload": [
                "type": "message", "role": role,
                "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]
            ]
        ]
    }
    func tokens(_ ts: String, _ rl: Any) -> [String: Any] {
        [
            "timestamp": ts, "type": "event_msg",
            "payload": ["type": "token_count", "info": NSNull(), "rate_limits": rl]
        ]
    }
    let f1 = try write(
        root, "2026/10/17/rollout-2026-10-17T10-00-00-\(id1).jsonl",
        [
            [
                "timestamp": "2026-10-17T10:00:00.100Z", "type": "session_meta",
                "payload": ["id": id1, "cwd": "/work/a", "timestamp": "2026-10-17T10:00:00.000Z"]
            ],
            item("user", "# AGENTS.md instructions for /work/a", "2026-10-17T10:00:01.000Z"),
            item("user", "<environment_context><cwd>/work/a</cwd></environment_context>", "2026-10-17T10:00:01.000Z"),
            [
                "timestamp": "2026-10-17T10:00:02.000Z", "type": "event_msg",
                "payload": ["type": "user_message", "message": "Refactor the parser"]
            ],
            item("user", "Refactor the parser", "2026-10-17T10:00:02.000Z"),
            item("assistant", "Done", "2026-10-17T10:01:00.000Z"),
            tokens(
                "2026-10-17T10:01:00.000Z",
                [
                    "primary": ["used_percent": 12.5, "window_minutes": 300, "resets_at": 1_792_000_000],
                    "secondary": ["used_percent": 40, "window_minutes": 10080, "resets_at": 1_792_500_000]
                ]),
            tokens("2026-10-17T10:02:00.000Z", ["primary": NSNull(), "secondary": NSNull(), "credits": NSNull()])
        ])
    try write(
        root, "2026/10/18/rollout-2026-10-18T09-00-00-\(id2).jsonl",
        [
            [
                "timestamp": "2026-10-18T09:00:00.000Z", "type": "session_meta",
                "payload": ["id": id2, "cwd": "/work/b", "timestamp": "2026-10-18T09:00:00.000Z"]
            ],
            item("user", "Old shape please", "2026-10-18T09:00:01.000Z"),
            tokens(
                "2026-10-18T09:05:00.000Z",
                ["primary": ["used_percent": 50, "window_minutes": 300, "resets_in_seconds": 600]])
        ])

    let s = CodexHistory.sessions(root: root)
    #expect(s.map(\.id) == [id2, id1])
    #expect(
        s[1].title == "Refactor the parser" && s[1].cwd == "/work/a" && s[1].messageCount == 4 && s[1].agent == .codex)
    #expect(s[0].title == "Old shape please")

    let l1 = try #require(CodexUsage.latest(in: f1))
    #expect(
        l1
            == CodexLimits(
                primaryUsedPercent: 12.5, primaryResetsAt: Date(timeIntervalSince1970: 1_792_000_000),
                secondaryUsedPercent: 40, secondaryResetsAt: Date(timeIntervalSince1970: 1_792_500_000),
                observedAt: date("2026-10-17T10:01:00.000Z"), primaryWindowMinutes: 300, secondaryWindowMinutes: 10080))
    let l = try #require(CodexUsage.latest(root: root))
    #expect(l.observedAt == date("2026-10-18T09:05:00.000Z") && l.primaryUsedPercent == 50)
    #expect(l.primaryResetsAt == date("2026-10-18T09:15:00.000Z") && l.secondaryUsedPercent == nil)

    let flat = CodexUsage.limits(
        tokens("2026-10-18T09:05:00Z", ["primary_used_percent": 7, "secondary_used_percent": 3]))
    #expect(flat?.primaryUsedPercent == 7 && flat?.secondaryUsedPercent == 3)

    // The free plan's one window is a month; the app server names its length differently.
    let at = Date(timeIntervalSince1970: 1_792_000_000)
    let free = CodexUsage.limits(
        rateLimits: [
            "primary": ["used_percent": 34, "window_minutes": 43200, "resets_at": 1_795_396_544], "secondary": NSNull()
        ], at: at)
    #expect(free?.primaryWindowMinutes == 43200 && free?.secondaryUsedPercent == nil)
    let server = CodexUsage.limits(rateLimits: ["primary": ["usedPercent": 5, "windowDurationMins": 300]], at: at)
    #expect(server?.primaryWindowMinutes == 300)

    // Conversations Codex Desktop imported from Claude Code: newer than the real ones, and without limits.
    for i in 0..<12 {
        let f = try write(
            root, "2026/10/20/rollout-2026-10-20T00-00-00-imported-\(i).jsonl",
            [tokens("2026-10-20T00:00:00.000Z", NSNull())])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.path)
    }
    #expect(CodexUsage.latest(root: root)?.primaryUsedPercent == 50)
}

@Test func searchAndResume() throws {
    let root = tmp(), p = root.appendingPathComponent("-work-demo")
    try write(
        p, "a.jsonl",
        [
            user("deploy the app", "2026-10-18T10:00:00Z", sid: "a"),
            assistant("m1", "r1", "2026-10-18T10:01:00Z", text: "the flux capacitor is fine")
        ])
    try write(
        p, "b.jsonl",
        [
            user("write docs", "2026-10-18T11:00:00Z", sid: "b"),
            assistant("m2", "r2", "2026-10-18T11:01:00Z", text: "nothing here")
        ])
    let s = ClaudeHistory.sessions(root: root)
    #expect(History.search(s, query: "DEPLOY").map(\.id) == ["a"])
    #expect(History.search(s, query: "/work/demo").count == 2)
    #expect(History.search(s, query: " ").count == 2)
    #expect(History.fullTextSearch(query: "Flux Capacitor", in: s).map(\.id) == ["a"])
    #expect(History.fullTextSearch(query: "the", in: s, limit: 1).count == 1)
    #expect(History.fullTextSearch(query: "", in: s).isEmpty)
}

@Test func missingDirsAreEmpty() {
    let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(ClaudeHistory.sessions(root: nowhere).isEmpty)
    #expect(CodexHistory.sessions(root: nowhere).isEmpty)
    #expect(
        UsageIndex(cache: nowhere.appendingPathComponent("c.json")).rows(roots: [nowhere], since: .distantPast).isEmpty)
    #expect(CodexUsage.latest(root: nowhere) == nil)
}

@Test func claudeSessionsForOneFolder() throws {
    let root = tmp().appendingPathComponent(UUID().uuidString)
    let dir = root.appendingPathComponent("-work-my-app")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let line =
        #"{"type":"user","sessionId":"abc","cwd":"/work/my_app","timestamp":"2026-10-19T00:00:00Z","message":{"content":"hi"}}"#
    try Data((line + "\n").utf8).write(to: dir.appendingPathComponent("abc.jsonl"))
    #expect(ClaudeHistory.sessions(cwd: "/work/my_app", root: root).map(\.id) == ["abc"])
    #expect(ClaudeHistory.sessions(cwd: "/work/other", root: root).isEmpty)
    // One by id, as waking a pinned session asks: found in any case, not in another folder, not when never written.
    #expect(ClaudeHistory.session(id: "ABC", cwd: "/work/my_app", root: root)?.id == "abc")
    #expect(ClaudeHistory.session(id: "abc", cwd: "/work/other", root: root) == nil)
    #expect(ClaudeHistory.session(id: "nope", cwd: "/work/my_app", root: root) == nil)
}

@Test func anHourLongCacheWriteCostsMoreThanAFiveMinuteOne() throws {
    let line =
        #"{"cwd":"/p","message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0,"#
        + #""cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}},"#
        + #""type":"assistant","timestamp":"2026-11-02T10:00:00.000Z"}"#
    #expect(try #require(UsageIndex.entry(Data(line.utf8))).cost == 8)
}

@Test func usageIndexReadsOnlyWhatsNew() throws {
    let dir = tmp().appendingPathComponent("ui-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("s.jsonl")
    func line(_ id: String, _ ts: String, _ out: Int) -> String {
        #"{"parentUuid":null,"cwd":"/p","message":{"id":"\#(id)","type":"message","role":"assistant","model":"claude-sonnet-4-5","#
            + #""content":[{"type":"text","text":"{ not usage }"}],"usage":{"input_tokens":10,"output_tokens":\#(out),"#
            + #""cache_creation":{"ephemeral_5m_input_tokens":0}}},"requestId":"r\#(id)","type":"assistant","timestamp":"\#(ts)"}"#
    }
    let now = ISO8601DateFormatter().string(from: Date())
    let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86400))   // copied in by a resume: before the file existed
    try [line("a", now, 5), line("a", now, 5), line("b", old, 100)].joined(separator: "\n").appending("\n").write(
        to: f, atomically: true, encoding: .utf8)
    let idx = UsageIndex(cache: dir.appendingPathComponent("cache.json"))
    let since = Date().addingTimeInterval(-7 * 86400)
    #expect(idx.rows(roots: [dir], since: since).reduce(0) { $0 + $1.tally.tokens.output } == 5)
    let h = try FileHandle(forWritingTo: f)
    try h.seekToEnd()
    try h.write(contentsOf: Data((line("c", now, 7) + "\n").utf8))
    try h.close()
    let again = UsageIndex(cache: dir.appendingPathComponent("cache.json"))   // from disk: the old part isn't read again
    let rows = again.rows(roots: [dir], since: since)
    #expect(rows.reduce(0) { $0 + $1.tally.tokens.output } == 12)
    #expect(rows.first?.cwd == "/p" && rows.first?.model == "claude-sonnet-4-5")
    // Read in 8 MB pieces from where the last read ended: a long line (a pasted image) puts the next one's end, usage
    // and all, past the first piece.
    let d = line("d", now, 30), g = try FileHandle(forWritingTo: f)
    try g.seekToEnd()
    try g.write(
        contentsOf: Data(
            (#"{"type":"user","text":""# + String(repeating: "x", count: (8 << 20) - 26 - d.utf8.count + 120) + "\"}\n"
                + d + "\n").utf8))
    try g.close()
    #expect(
        UsageIndex(cache: dir.appendingPathComponent("cache.json")).rows(roots: [dir], since: since).reduce(0) {
            $0 + $1.tally.tokens.output
        } == 42)
    // A line still being written waits, after the lines before it are read; once it ends, it counts once.
    func total() -> Int {
        UsageIndex(cache: dir.appendingPathComponent("cache.json")).rows(roots: [dir], since: since).reduce(0) {
            $0 + $1.tally.tokens.output
        }
    }
    let e = Data(line("e", now, 100).utf8), half = e.count / 2
    let k = try FileHandle(forWritingTo: f)
    try k.seekToEnd()
    try k.write(contentsOf: Data((line("f", now, 1) + "\n").utf8) + e[..<half])
    #expect(total() == 43)
    try k.write(contentsOf: e[half...] + Data("\n".utf8))
    try k.close()
    #expect(total() == 143)
    #expect(total() == 143)
}

@Test func timesAndDaysReadTheWayTranscriptsWriteThem() throws {
    let a = try #require(JSONL.date("2026-10-20T10:15:30.250Z")?.timeIntervalSince1970),
        b = try #require(JSONL.date("2026-10-20T10:15:30Z")?.timeIntervalSince1970)
    #expect(abs(a - b - 0.25) < 0.001)   // with and without fractional seconds
    #expect(JSONL.date("not a time") == nil)
    var c = Calendar.current
    c.timeZone = .current
    let noon = try #require(c.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
    #expect(UsageIndex.day(noon) == "2026-03-07")   // the local day, zero-padded
}

/// What fills the context: since the last /compact, by part (Read by file, Bash by command, the conversation), scaled to
/// the tokens the last reply counted on top of the first request's base.
@Test func contextPartsSinceTheLastCompaction() throws {
    func line(_ o: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self)
    }
    func reply(_ input: Int, _ blocks: [[String: Any]]) -> String {
        line(["type": "assistant", "message": ["content": blocks, "usage": ["input_tokens": input]]])
    }
    func results(_ r: [(String, String)]) -> String {
        line([
            "type": "user",
            "message": ["content": r.map { ["type": "tool_result", "tool_use_id": $0.0, "content": $0.1] }]
        ])
    }
    let old = [
        line(["type": "user", "message": ["content": String(repeating: "x", count: 400)]]),
        reply(1100, [["type": "text", "text": "hi"]]),
        results([("gone", String(repeating: "g", count: 9000))])
    ]
    let now = [
        line([
            "type": "system", "subtype": "compact_boundary", "compactMetadata": ["preTokens": 9000, "postTokens": 300]
        ]),
        line(["type": "user", "isCompactSummary": true, "message": ["content": String(repeating: "s", count: 400)]]),
        reply(
            1200,
            [
                ["type": "tool_use", "id": "r1", "name": "Read", "input": ["file_path": "/a/payment.ts"]],
                ["type": "tool_use", "id": "b1", "name": "Bash", "input": ["command": "cd app && npm test -- --ci"]],
                ["type": "tool_use", "id": "b2", "name": "Bash", "input": ["command": "npm test"]]
            ]),
        results([
            ("r1", String(repeating: "f", count: 2000)), ("b1", String(repeating: "t", count: 1000)),
            ("b2", String(repeating: "t", count: 1000))
        ]),
        line(["type": "attachment", "rendered": [["content": String(repeating: "n", count: 200)]]]),
        line(["type": "user", "isSidechain": true, "message": ["content": String(repeating: "z", count: 8000)]]),   // a subagent's
        reply(2400, [["type": "text", "text": "Done"]])
    ]
    let data = Data((old + now).joined(separator: "\n").utf8)
    let p = try #require(ClaudeContext.parts(data, used: 2400))
    #expect(p.base == 932)   // the first request, less what was typed (400 / 2.37)
    #expect(p.parts.map(\.kind) == [.files, .commands, .conversation, .summary])
    let files = try #require(p.parts.first), cmds = p.parts[1]
    #expect(files.top.map(\.label) == ["payment.ts"])
    #expect(cmds.top.map(\.label) == ["npm test"] && cmds.top[0].count == 2)   // both runs, under one name
    #expect(files.tokens == cmds.tokens)   // 2000 characters each
    let sum = p.base + p.parts.reduce(0) { $0 + $1.tokens }
    #expect((2390...2400).contains(sum))   // scaled to what the reply counted
    #expect(ClaudeContext.parts(Data(old.joined(separator: "\n").utf8), used: 0) == nil)

    // Thinking stays in the context; each of a reply's lines repeats its usage, so it counts once.
    let thought = line([
        "type": "assistant",
        "message": [
            "id": "m1", "content": [["type": "thinking", "thinking": ""]],
            "usage": ["input_tokens": 3000, "output_tokens_details": ["thinking_tokens": 100]]
        ]
    ])
    let t = try #require(
        ClaudeContext.parts(Data((old + now + [thought, thought]).joined(separator: "\n").utf8), used: 3000))
    let conversation = try #require(t.parts.first { $0.kind == .conversation })
    let item = try #require(conversation.top.first { $0.label == "thinking" })
    #expect(item.tokens * 2 > conversation.top.filter { $0.label != "thinking" }.reduce(0) { $0 + $1.tokens })   // 237 characters, once
}

/// What every request starts with, as `claude -p /context` prints it: the categories (not Messages or Free space, read
/// elsewhere), the deferred tools and the buffer apart, the memory files and skills it lists under their category.
@Test func contextSetupFromClaudeCodesOwnCount() throws {
    let printed = """
        ## Context Usage

        **Tokens:** 26.3k / 1m (3%)

        ### Estimated usage by category

        | Category | Tokens | Percentage |
        |----------|--------|------------|
        | System prompt | 2.5k | 0.2% |
        | System tools | 578 | 0.1% |
        | MCP tools (deferred) | 57.5k | 5.8% |
        | Memory files | 7.8k | 0.8% |
        | Skills | 1.2k | 0.1% |
        | Messages | 2k | 0.2% |
        | Free space | 940.7k | 94.1% |
        | Autocompact buffer | 33k | 3.3% |

        ### MCP Tools

        | Tool | Server | Tokens |
        |------|--------|--------|
        | mcp__x__y | x | 153 |

        ### Memory Files

        | Type | Path | Tokens |
        |------|------|--------|
        | Project | /Users/me/app/CLAUDE.md | 4k |
        | AutoMem | /Users/me/.claude/projects/app/memory/MEMORY.md | 3.8k |

        ### Skills

        | Skill | Source | Tokens |
        |-------|--------|--------|
        | find-skills | User | ~110 |
        | tabbit | User | ~40 |
        | transitions-dev | User | ~520 |
        | review | Plugin | ~300 |
        """
    let s = try #require(ClaudeContext.setup(printed))
    #expect(s.parts.map(\.label) == ["System prompt", "System tools", "Memory files", "Skills"])
    #expect(s.parts.map(\.tokens) == [2500, 578, 7800, 1200])
    #expect(s.deferred == [.init(label: "MCP tools (deferred)", tokens: 57_500)])
    #expect(s.buffer == 33_000)
    #expect(s.parts[2].top.map(\.label) == ["CLAUDE.md", "MEMORY.md"])
    #expect(s.parts[3].top.map(\.label) == ["transitions-dev", "review", "find-skills"] && s.parts[3].more == 1)
    #expect(ClaudeContext.setup("Error: not logged in") == nil)
    // What else the first request held is one more part; one that counts more than the request held is scaled down.
    let more = ClaudeContext.fit(s, to: 20_078)
    #expect(more.parts.map(\.label).last == "Other" && more.parts.last?.tokens == 8000 && more.parts[2].tokens == 7800)
    let less = ClaudeContext.fit(s, to: 6_039)
    #expect(less.parts.count == 4 && less.parts[2].top[0].tokens == 2000 && less.buffer == 33_000)   // half: 12,078 counted, 6,039 sent
}

private func step(_ tool: String, _ input: [String: Any], _ ts: String) -> [String: Any] {
    [
        "type": "assistant", "cwd": "/work/demo", "timestamp": ts,
        "message": [
            "model": "claude-opus-5-5", "content": [["type": "tool_use", "name": tool, "input": input]],
            "usage": ["input_tokens": 2, "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40]
        ]
    ]
}

@Test func aSubagentsTranscriptStaysInItsFolder() {
    let parent = URL(fileURLWithPath: "/p/0F.jsonl")
    #expect(SubagentTranscript.file(parent: parent, id: "a1")?.path == "/p/0F/subagents/agent-a1.jsonl")
    #expect(
        SubagentTranscript.file(parent: URL(fileURLWithPath: "/p/0F/subagents/agent-b.jsonl"), id: "a1")?.path
            == "/p/0F/subagents/agent-a1.jsonl")
    #expect(SubagentTranscript.file(parent: parent, id: "../../secret") == nil)
    #expect(SubagentTranscript.file(parent: parent, id: "") == nil)
}

@Test func aSubagentsJournalHasItsStepsAndReport() throws {
    let dir = tmp().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
        dir, "agent-a.jsonl",
        [
            user("Review it", "2026-11-02T06:25:11.963Z"), "not json",
            step("Read", ["file_path": "/work/demo/Sources/A.swift"], "2026-11-02T06:25:15.000Z"),
            step("Bash", ["command": "grep -n x\nsecond line"], "2026-11-02T06:25:20.000Z"),
            step("SubagentHandback", ["message": "All good."], "2026-11-02T06:25:30.000Z")
        ])
    try Data(#"{"agentType":"Explore","description":"Counts files"}"#.utf8).write(
        to: dir.appendingPathComponent("agent-a.meta.json"))
    let j = try SubagentTranscript.journal(url)
    #expect(j.kind == "Explore" && j.task == "Counts files" && j.model == "claude-opus-5-5" && j.context == 342)
    #expect(j.steps.map(\.tool) == ["Read", "Bash"])
    #expect(j.steps.map(\.detail) == ["Sources/A.swift", "grep -n x"])
    #expect(j.report == "All good.")
    #expect(SubagentTranscript.lastStep(tail: try Data(contentsOf: url))?.tool == "Bash")
}

@Test func aSubagentWithoutAHandbackReportsItsLastWords() throws {
    let dir = tmp().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try write(
        dir, "agent-a.jsonl", [assistant("m", "r", "2026-11-02T06:25:15.000Z", text: "Done, nothing found.")])
    #expect(try SubagentTranscript.journal(url).report == "Done, nothing found.")
}

/// The index is megabytes and some log always grew: it reaches the disk once, then every few minutes.
@Test func theUsageIndexIsNotRewrittenOnEveryRead() throws {
    let dir = tmp().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appendingPathComponent("s.jsonl"), cache = dir.appendingPathComponent("cache.json")
    try "{}\n".write(to: f, atomically: true, encoding: .utf8)
    let idx = UsageIndex(cache: cache)
    _ = idx.rows(roots: [dir], since: .distantPast)
    let first = try Data(contentsOf: cache)
    let h = try FileHandle(forWritingTo: f)
    try h.seekToEnd()
    try h.write(contentsOf: Data("{}\n".utf8))
    try h.close()
    _ = idx.rows(roots: [dir], since: .distantPast)
    #expect(try Data(contentsOf: cache) == first)
}

/// What a chat spent on a page: its calls in the page's time, each once, priced.
@Test func aChatsSpendingBetweenTwoTimesCountsEachCallOnce() throws {
    let f = tmp().appendingPathComponent("spent-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: f) }
    func line(_ id: String, _ ts: String, _ out: Int) -> String {
        #"{"cwd":"/p","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":100,"#
            + #""output_tokens":\#(out),"cache_read_input_tokens":1000}},"type":"assistant","timestamp":"\#(ts)"}"#
    }
    try [
        line("z", "2026-11-10T09:00:00.000Z", 900), line("a", "2026-11-10T10:00:00.000Z", 50),
        line("a", "2026-11-10T10:00:00.000Z", 50), line("b", "2026-11-10T10:05:00.000Z", 70),
        line("c", "2026-11-10T12:00:00.000Z", 900)
    ].joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    let from = try #require(ISO8601DateFormatter().date(from: "2026-11-10T09:59:00Z")).timeIntervalSince1970
    let spent = ClaudeUsage.spent(transcript: f, from: from, to: from + 3600)
    #expect(spent.calls == 2 && spent.tokens.output == 120 && spent.tokens.cacheRead == 2000)
    #expect(abs(spent.cost - Pricing.cost(model: "claude-opus-5-5", tokens: spent.tokens)) < 1e-9)
}
