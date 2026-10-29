import Foundation
import SQLite3

/// What GitHub Copilot CLI used: a row per model call in its `session-store.db` (`assistant_usage_events`; its input counts
/// the cache), the folder from its session.
public enum CopilotUsage {
    public static var database: URL {
        (ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")).appendingPathComponent("session-store.db")
    }

    /// From a copy of the database, never Copilot's own: it keeps the newest rows in the WAL, which only a connection
    /// that may write applies, and Kelp doesn't write to an agent's files.
    public static func rows(copy db: URL, since: Date) -> [UsageIndex.Row] {
        var h: OpaquePointer?
        defer { sqlite3_close(h) }
        guard sqlite3_open_v2(db.path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [] }
        return UsageIndex.rows(entries(h, since: since))
    }

    /// The same call is sometimes stored twice under another turn (same session, time and counts): DISTINCT keeps one.
    static func entries(_ h: OpaquePointer?, since: Date) -> [UsageEntry] {
        let sql = """
            SELECT DISTINCT e.session_id, e.created_at, e.model, e.input_tokens, e.output_tokens, e.cache_read_tokens,
                            e.cache_write_tokens, COALESCE(s.cwd, '')
            FROM assistant_usage_events e LEFT JOIN sessions s ON s.id = e.session_id
            """
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
        var out: [UsageEntry] = []
        while sqlite3_step(st) == SQLITE_ROW {
            // ISO with a "Z", or SQLite's own "2026-10-25 01:17:12" (UTC) when a row took the column's default.
            guard let t = JSONL.date(text(1)) ?? JSONL.date(text(1).replacingOccurrences(of: " ", with: "T") + "Z"), t >= since else { continue }
            let read = int(5), written = int(6)
            out.append(UsageEntry(time: t.timeIntervalSince1970, model: text(2), cwd: text(7), id: nil,
                                  tokens: TokenCounts(input: max(0, int(3) - read - written), output: int(4), cacheWrite: written, cacheRead: read)))
        }
        return out
    }
}
