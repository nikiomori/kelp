import Foundation
import SQLite3
import Testing
@testable import AgentData

private func scratch() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("uf-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ url: URL, _ lines: [[String: Any]]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
    try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func iso(_ t: Date) -> String { ISO8601DateFormatter().string(from: t) }

/// Codex: the model and folder come from earlier lines; a snapshot written twice, an estimate with only a total and a
/// fork's replay of its parent count for nothing.
@Test func codexRolloutsCountEachCallOnce() throws {
    let dir = try scratch(), now = Date()
    func tokens(_ at: TimeInterval, _ input: Int, _ cached: Int, _ out: Int, total: Int) -> [String: Any] {
        ["timestamp": iso(now + at), "type": "event_msg", "payload": ["type": "token_count", "info": [
            "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": out],
            "total_token_usage": ["total_tokens": total]]]]
    }
    try write(dir.appendingPathComponent("2026/10/29/rollout-a.jsonl"), [
        ["timestamp": iso(now), "type": "session_meta", "payload": ["cwd": "/p/app", "forked_from_id": "parent"]],
        tokens(0.5, 1000, 0, 50, total: 1050),                       // the parent's, replayed when it forked
        ["timestamp": iso(now + 5), "type": "turn_context", "payload": ["model": "gpt-5.5", "cwd": "/p/app"]],
        tokens(10, 300, 200, 20, total: 1370),
        tokens(10.1, 300, 200, 20, total: 1370),                     // the same snapshot again
        tokens(11, 0, 0, 0, total: 6370)                             // an estimate: a total and nothing else
    ])
    let rows = UsageIndex(cache: dir.appendingPathComponent("c.json"), format: .codex).rows(roots: [dir], since: now - 86400)
    #expect(rows.count == 1)
    #expect(rows.first?.model == "gpt-5.5" && rows.first?.cwd == "/p/app")
    #expect(rows.first?.tally.tokens == TokenCounts(input: 100, output: 20, cacheWrite: 0, cacheRead: 200))
}

/// Grok: what it says a turn cost, the model that took most of it, the folder from the session's summary; a subagent's
/// turns are in its parent's already, and a forked copy of a turn counts once.
@Test func grokTurnsCountWithTheirOwnCost() throws {
    let dir = try scratch(), ms = Date().timeIntervalSince1970 * 1000
    let turn: [String: Any] = ["method": "_x.ai/session/update", "params": [
        "update": ["sessionUpdate": "turn_completed", "prompt_id": "p1", "usage": [
            "inputTokens": 1000, "outputTokens": 30, "cachedReadTokens": 800, "cacheCreationTokens": 0, "costUsdTicks": 500_000_000,
            "modelUsage": ["grok-4.7-build": ["totalTokens": 1020], "grok-mini": ["totalTokens": 10]]]],
        "_meta": ["agentTimestampMs": ms]]]
    let main = dir.appendingPathComponent("%2Fp%2Fweb/s1"), sub = dir.appendingPathComponent("%2Fp%2Fweb/s2")
    try write(main.appendingPathComponent("updates.jsonl"), [turn, turn])
    try write(main.appendingPathComponent("summary.json"), [["info": ["cwd": "/p/web"]]])
    try write(sub.appendingPathComponent("updates.jsonl"), [turn])
    try write(sub.appendingPathComponent("summary.json"), [["session_kind": "subagent", "info": ["cwd": "/p/web"]]])
    let rows = UsageIndex(cache: dir.appendingPathComponent("c.json"), format: .grok).rows(roots: [dir], since: Date() - 86400)
    #expect(rows.count == 1)
    #expect(rows.first?.model == "grok-4.7-build" && rows.first?.cwd == "/p/web")
    #expect(rows.first?.tally.tokens == TokenCounts(input: 200, output: 30, cacheWrite: 0, cacheRead: 800))
    #expect(abs((rows.first?.tally.cost ?? 0) - 0.05) < 1e-9)
}

@Test func kimiRecordsCountWithTheirSessionsFolder() throws {
    let dir = try scratch(), session = dir.appendingPathComponent("wd_app_1/session_1")
    try write(session.appendingPathComponent("state.json"), [["cwd": "/p/kimi"]])
    try write(session.appendingPathComponent("agents/main/wire.jsonl"), [
        ["type": "usage.record", "model": "kimi-k3", "time": Date().timeIntervalSince1970 * 1000,
         "usage": ["inputOther": 10, "output": 5, "inputCacheRead": 7, "inputCacheCreation": 1]],
        ["type": "token_counting.turn_recorded", "tokens": 999]   // a context estimate, not usage
    ])
    let rows = UsageIndex(cache: dir.appendingPathComponent("c.json"), format: .kimi).rows(roots: [dir], since: Date() - 86400)
    #expect(rows.map(\.cwd) == ["/p/kimi"])
    #expect(rows.first?.tally.tokens == TokenCounts(input: 10, output: 5, cacheWrite: 1, cacheRead: 7))
}

/// Copilot stores some calls twice under another turn: each counts once, its input without the cache.
@Test func copilotCallsStoredTwiceCountOnce() throws {
    let home = try scratch()
    var h: OpaquePointer?
    #expect(sqlite3_open(home.appendingPathComponent("session-store.db").path, &h) == SQLITE_OK)
    let now = iso(Date())
    let sql = """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT);
        CREATE TABLE assistant_usage_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, turn_index INTEGER, model TEXT,
            input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, created_at TEXT);
        INSERT INTO sessions VALUES ('s', '/p/cop');
        INSERT INTO assistant_usage_events VALUES (NULL, 's', 0, 'gpt-6-luna', 1000, 40, 600, 100, '\(now)');
        INSERT INTO assistant_usage_events VALUES (NULL, 's', 1, 'gpt-6-luna', 1000, 40, 600, 100, '\(now)');
        INSERT INTO assistant_usage_events VALUES (NULL, 's', 1, 'gpt-6-luna', 50, 5, 0, 0, '2020-01-01 00:00:00');
        """
    #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(h)
    let rows = AgentDatabases.rows("copilot", copies: [home.appendingPathComponent("session-store.db")], since: Date() - 86400)
    #expect(rows.map(\.cwd) == ["/p/cop"])
    #expect(rows.first?.tally.tokens == TokenCounts(input: 300, output: 40, cacheWrite: 100, cacheRead: 600))
}

/// pi and oh-my-pi: the folder from the session line, what pi priced a reply at; a line copied in by a fork is older than
/// the file and counts for nothing.
@Test func piRepliesCountWithTheirFolderAndPrice() throws {
    let dir = try scratch(), ms = Date().timeIntervalSince1970 * 1000
    func reply(_ at: Double, _ input: Int) -> [String: Any] {
        ["type": "message", "message": ["role": "assistant", "model": "glm-5.3", "timestamp": at, "responseId": "r\(input)",
                                        "usage": ["input": input, "output": 20, "cacheRead": 300, "cacheWrite": 0, "cost": ["total": 0.01]]]]
    }
    try write(dir.appendingPathComponent("--p-app--/a.jsonl"), [
        ["type": "session", "cwd": "/p/app"], reply(ms - 5 * 86_400_000, 999), reply(ms, 100), ["type": "message", "message": ["role": "user"]]
    ])
    let rows = UsageIndex(cache: dir.appendingPathComponent("c.json"), format: .pi).rows(roots: [dir], since: Date() - 30 * 86400)
    #expect(rows.map(\.cwd) == ["/p/app"] && rows.first?.model == "glm-5.3")
    #expect(rows.first?.tally.tokens == TokenCounts(input: 100, output: 20, cacheWrite: 0, cacheRead: 300))
    #expect(abs((rows.first?.tally.cost ?? 0) - 0.01) < 1e-9)
}

/// Qwen Code and Gemini CLI write Gemini's numbers: the prompt (Gemini: input) counts the cache; Gemini writes a reply
/// again once its tokens come, under the same id.
@Test func qwenAndGeminiCountTheCacheOnce() throws {
    let dir = try scratch(), now = iso(Date())
    try write(dir.appendingPathComponent("-p-q/chats/s.jsonl"), [
        ["type": "assistant", "uuid": "u1", "cwd": "/p/q", "model": "qwen3-coder", "timestamp": now,
         "usageMetadata": ["promptTokenCount": 1000, "cachedContentTokenCount": 600, "candidatesTokenCount": 40, "totalTokenCount": 1050]]
    ])
    let q = UsageIndex(cache: dir.appendingPathComponent("q.json"), format: .qwen).rows(roots: [dir], since: Date() - 86400)
    #expect(q.first?.tally.tokens == TokenCounts(input: 400, output: 50, cacheWrite: 0, cacheRead: 600) && q.first?.cwd == "/p/q")

    let gem = try scratch()
    try write(gem.appendingPathComponent("projects.json"), [["projects": ["/p/g": "g-app"]]])
    let reply: [String: Any] = ["id": "m1", "type": "gemini", "timestamp": now, "model": "gemini-3-pro",
                                "tokens": ["input": 900, "output": 30, "cached": 500, "thoughts": 10, "total": 940]]
    try write(gem.appendingPathComponent("tmp/g-app/chats/session-1.jsonl"), [["id": "m1", "type": "gemini", "timestamp": now], reply, reply])
    let g = UsageIndex(cache: gem.appendingPathComponent("c.json"), format: .gemini).rows(roots: [gem.appendingPathComponent("tmp")], since: Date() - 86400)
    #expect(g.first?.tally.tokens == TokenCounts(input: 400, output: 40, cacheWrite: 0, cacheRead: 500) && g.first?.cwd == "/p/g")
}

/// OpenCode and Kilo: complete assistant messages, reasoning counted as output; what it says it cost.
@Test func openCodeMessagesCountWhenComplete() throws {
    let dir = try scratch(), db = dir.appendingPathComponent("opencode.db"), ms = Int(Date().timeIntervalSince1970 * 1000)
    func message(_ completed: Bool) -> String {
        let time = completed ? #"{"created":\#(ms),"completed":\#(ms + 900)}"# : #"{"created":\#(ms)}"#
        return #"{"role":"assistant","modelID":"step-5","cost":0.25,"path":{"cwd":"/p/oc"},"time":\#(time),"#
            + #""tokens":{"input":10,"output":5,"reasoning":3,"cache":{"read":70,"write":2}}}"#
    }
    try sql(db, """
        CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);
        INSERT INTO session VALUES ('s', '/p/oc');
        INSERT INTO message VALUES ('a', 's', \(ms), '\(message(true))');
        INSERT INTO message VALUES ('b', 's', \(ms), '\(message(false))');
        INSERT INTO message VALUES ('c', 's', \(ms), '{"role":"user"}');
        """)
    let rows = AgentDatabases.rows("opencode", copies: [db], since: Date() - 86400)
    #expect(rows.first?.tally.tokens == TokenCounts(input: 10, output: 8, cacheWrite: 2, cacheRead: 70) && rows.first?.cwd == "/p/oc")
    #expect(rows.first?.tally.cost == 0.25)
}

/// Antigravity: protobuf per call; the time from its steps, the folder from the conversation; a call cut short (no usage)
/// counts for nothing.
@Test func antigravityCallsDecodeFromProtobuf() throws {
    func varint(_ n: UInt64) -> [UInt8] { var n = n, out: [UInt8] = []; repeat { out.append(UInt8(n & 0x7F) | (n > 0x7F ? 0x80 : 0)); n >>= 7 } while n > 0; return out }
    func num(_ f: UInt64, _ n: UInt64) -> [UInt8] { varint(f << 3) + varint(n) }
    func bytes(_ f: UInt64, _ b: [UInt8]) -> [UInt8] { varint(f << 3 | 2) + varint(UInt64(b.count)) + b }
    func hex(_ b: [UInt8]) -> String { "X'" + b.map { String(format: "%02x", $0) }.joined() + "'" }
    let now = UInt64(Date().timeIntervalSince1970)
    let usage = num(2, 2313) + num(3, 120) + num(5, 64140) + bytes(11, Array("r1".utf8))
    let call = bytes(1, bytes(4, usage) + bytes(19, Array("gemini-3.8-flash".utf8))) + bytes(2, varint(7) + varint(8))
    let aborted = bytes(1, bytes(4, []) + bytes(19, Array("gemini-3.8-flash".utf8))) + bytes(2, varint(9))
    let dir = try scratch(), db = dir.appendingPathComponent("c.db")
    try sql(db, """
        CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);
        CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB);
        CREATE TABLE trajectory_metadata_blob (id TEXT PRIMARY KEY, data BLOB);
        INSERT INTO gen_metadata VALUES (1, \(hex(call))), (2, \(hex(aborted)));
        INSERT INTO steps VALUES (7, \(hex(bytes(1, num(1, now + 5))))), (8, \(hex(bytes(1, num(1, now))))), (9, \(hex(bytes(1, num(1, now)))));
        INSERT INTO trajectory_metadata_blob VALUES ('main', \(hex(bytes(7, Array("file:///p/agy".utf8)))));
        """)
    let rows = AgentDatabases.rows("antigravity", copies: [db], since: Date() - 86400)
    #expect(rows.count == 1 && rows.first?.model == "gemini-3.8-flash" && rows.first?.cwd == "/p/agy")
    #expect(rows.first?.tally.tokens == TokenCounts(input: 2313, output: 120, cacheWrite: 0, cacheRead: 64140))
}

private func sql(_ db: URL, _ text: String) throws {
    var h: OpaquePointer?
    defer { sqlite3_close(h) }
    try #require(sqlite3_open(db.path, &h) == SQLITE_OK)
    try #require(sqlite3_exec(h, text, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(h)))")
}
