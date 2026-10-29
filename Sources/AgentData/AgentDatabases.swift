import Foundation
import SQLite3

/// Agents that keep their calls in SQLite: GitHub Copilot CLI, OpenCode and Kilo (one database each), Antigravity (one per
/// conversation). Read from copies the daemon makes, never the agent's own files: the newest rows sit in the WAL, which only
/// a connection that may write applies, and Kelp doesn't write to an agent's files.
public enum AgentDatabases {
    public static let agents = ["copilot", "opencode", "kilo", "antigravity"]

    /// `agent`'s databases changed since `since` (an older one has nothing newer in it).
    public static func files(_ agent: String, changedSince since: Date) -> [URL] {
        let env = ProcessInfo.processInfo.environment, fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        func dir(_ variable: String, _ fallback: String) -> URL { env[variable].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(fallback) }
        let data = dir("XDG_DATA_HOME", ".local/share")
        let all: [URL] = switch agent {
        case "copilot": [dir("COPILOT_HOME", ".copilot").appendingPathComponent("session-store.db")]
        case "opencode": [env["OPENCODE_DB"].map { URL(fileURLWithPath: $0) } ?? data.appendingPathComponent("opencode/opencode.db")]
        case "kilo": [data.appendingPathComponent("kilo/kilo.db")]
        case "antigravity":
            (fm.enumerator(at: home.appendingPathComponent(".gemini/antigravity-cli/conversations"), includingPropertiesForKeys: nil,
                           options: .skipsSubdirectoryDescendants)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "db" }
        default: []
        }
        func changed(_ path: String) -> TimeInterval {
            var s = stat()
            return stat(path, &s) == 0 ? TimeInterval(s.st_mtimespec.tv_sec) : 0
        }
        return all.filter { max(changed($0.path), changed($0.path + "-wal")) >= since.timeIntervalSince1970 }
    }

    public static func rows(_ agent: String, copies: [URL], since: Date) -> [UsageIndex.Row] {
        UsageIndex.rows(copies.flatMap { db -> [UsageEntry] in
            switch agent {
            case "copilot": copilot(db, since: since)
            case "opencode", "kilo": openCode(db, since: since)
            case "antigravity": antigravity(db, since: since)
            default: []
            }
        })
    }

    /// Copilot: `assistant_usage_events` (input counts the cache), the folder from its session. The same call is sometimes
    /// stored twice under another turn (same session, time and counts): DISTINCT keeps one.
    static func copilot(_ db: URL, since: Date) -> [UsageEntry] {
        var out: [UsageEntry] = []
        query(db, """
            SELECT DISTINCT e.session_id, e.created_at, e.model, e.input_tokens, e.output_tokens, e.cache_read_tokens,
                            e.cache_write_tokens, COALESCE(s.cwd, '')
            FROM assistant_usage_events e LEFT JOIN sessions s ON s.id = e.session_id
            """) { st in
            // ISO with a "Z", or SQLite's own "2026-10-25 01:17:12" (UTC) when a row took the column's default.
            let at = text(st, 1)
            guard let t = JSONL.date(at) ?? JSONL.date(at.replacingOccurrences(of: " ", with: "T") + "Z"), t >= since else { return }
            let read = int(st, 5), written = int(st, 6)
            out.append(UsageEntry(time: t.timeIntervalSince1970, model: text(st, 2), cwd: text(st, 7), id: nil,
                                  tokens: TokenCounts(input: max(0, int(st, 3) - read - written), output: int(st, 4), cacheWrite: written, cacheRead: read)))
        }
        return out
    }

    /// OpenCode and Kilo: an assistant message's JSON once it's complete: `tokens` (input without the cache, output without
    /// the reasoning) and what it cost by its own account.
    static func openCode(_ db: URL, since: Date) -> [UsageEntry] {
        var out: [UsageEntry] = []
        query(db, "SELECT m.data, s.directory FROM message m JOIN session s ON s.id = m.session_id WHERE m.time_created >= ?",
              Int64(since.timeIntervalSince1970 * 1000)) { st in
            guard let o = JSONL.object(Data(text(st, 0).utf8)), o["role"] as? String == "assistant",
                  let time = o["time"] as? [String: Any], time["completed"] != nil,
                  let created = (time["created"] as? NSNumber)?.doubleValue, let t = o["tokens"] as? [String: Any] else { return }
            let cache = t["cache"] as? [String: Any] ?? [:]
            let tokens = TokenCounts(input: JSONL.int(t, "input"), output: JSONL.int(t, "output") + JSONL.int(t, "reasoning"),
                                     cacheWrite: JSONL.int(cache, "write"), cacheRead: JSONL.int(cache, "read"))
            guard tokens.total > 0 else { return }
            let cost = (o["cost"] as? NSNumber)?.doubleValue ?? 0
            out.append(UsageEntry(time: created / 1000, model: o["modelID"] as? String ?? "opencode",
                                  cwd: (o["path"] as? [String: Any])?["cwd"] as? String ?? text(st, 1), id: nil, tokens: tokens,
                                  cost: cost > 0 ? cost : nil))
        }
        return out
    }

    /// Antigravity: a protobuf per model call in `gen_metadata` (1 the call: 4 its usage — 2 input without the cache,
    /// 3 output, 4 cache writes, 5 cache reads; 19 the model; 2 its steps), the time from those steps (`steps`: 1 created,
    /// 1 seconds), the folder from the conversation (`trajectory_metadata_blob`: 7 its workspaces). A call cut short has none.
    static func antigravity(_ db: URL, since: Date) -> [UsageEntry] {
        var started: [Int: Double] = [:], cwd = ""
        query(db, "SELECT idx, metadata FROM steps") { st in
            guard let at = Proto.message(blob(st, 1), 1).flatMap({ Proto.number($0, 1) }) else { return }
            started[int(st, 0)] = Double(at)
        }
        query(db, "SELECT data FROM trajectory_metadata_blob WHERE id = 'main'") { st in
            cwd = Proto.string(blob(st, 0), 7).flatMap { URL(string: $0)?.path } ?? ""
        }
        var out: [UsageEntry] = []
        query(db, "SELECT data FROM gen_metadata") { st in
            let top = blob(st, 0)
            guard let call = Proto.message(top, 1), let usage = Proto.message(call, 4) else { return }
            let tokens = TokenCounts(input: Proto.number(usage, 2).map(Int.init) ?? 0, output: Proto.number(usage, 3).map(Int.init) ?? 0,
                                     cacheWrite: Proto.number(usage, 4).map(Int.init) ?? 0, cacheRead: Proto.number(usage, 5).map(Int.init) ?? 0)
            let steps = Proto.message(top, 2).map(Proto.packed) ?? Proto.number(top, 2).map { [$0] } ?? []
            guard tokens.total > 0, let t = steps.compactMap({ started[Int($0)] }).min(), t >= since.timeIntervalSince1970 else { return }
            out.append(UsageEntry(time: t, model: Proto.string(call, 19) ?? "antigravity", cwd: cwd, id: nil, tokens: tokens))
        }
        return out
    }

    private static func query(_ db: URL, _ sql: String, _ arg: Int64? = nil, row: (OpaquePointer) -> Void) {
        var h: OpaquePointer?, st: OpaquePointer?
        defer { sqlite3_finalize(st); sqlite3_close(h) }
        guard sqlite3_open_v2(db.path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        if let arg { sqlite3_bind_int64(st, 1, arg) }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }
    private static func text(_ st: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
    private static func int(_ st: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
    private static func blob(_ st: OpaquePointer, _ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, i)))
    }
}

/// Protocol Buffers' wire format, as much as Antigravity's numbers need: the first value of a field, a number or the bytes
/// of a string or nested message.
enum Proto {
    static func number(_ d: Data, _ field: Int) -> UInt64? { if case .number(let n)? = first(d, field) { n } else { nil } }
    static func message(_ d: Data, _ field: Int) -> Data? { if case .bytes(let b)? = first(d, field) { b } else { nil } }
    static func string(_ d: Data, _ field: Int) -> String? { message(d, field).flatMap { String(data: $0, encoding: .utf8) } }

    /// A packed repeated number field's values.
    static func packed(_ d: Data) -> [UInt64] {
        let b = [UInt8](d)
        var i = 0, out: [UInt64] = []
        while i < b.count, let n = varint(b, &i) { out.append(n) }
        return out
    }

    private enum Value { case number(UInt64), bytes(Data) }

    private static func first(_ d: Data, _ field: Int) -> Value? {
        let b = [UInt8](d)
        var i = 0
        while i < b.count, let key = varint(b, &i) {
            let wire = key & 7, here = Int(key >> 3) == field
            switch wire {
            case 0: guard let n = varint(b, &i) else { return nil }; if here { return .number(n) }
            case 2:
                guard let len = varint(b, &i), len <= UInt64(b.count - i) else { return nil }
                if here { return .bytes(Data(b[i..<i + Int(len)])) }
                i += Int(len)
            case 1: i += 8
            case 5: i += 4
            default: return nil   // groups: not in these messages
            }
        }
        return nil
    }

    private static func varint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var n: UInt64 = 0, shift: UInt64 = 0
        while i < b.count, shift < 64 {
            let x = b[i]; i += 1
            n |= UInt64(x & 0x7F) << shift
            if x < 0x80 { return n }
            shift += 7
        }
        return nil
    }
}
