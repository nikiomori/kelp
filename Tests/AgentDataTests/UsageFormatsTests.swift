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
    let rows = CopilotUsage.rows(copy: home.appendingPathComponent("session-store.db"), since: Date() - 86400)
    #expect(rows.map(\.cwd) == ["/p/cop"])
    #expect(rows.first?.tally.tokens == TokenCounts(input: 300, output: 40, cacheWrite: 100, cacheRead: 600))
}
