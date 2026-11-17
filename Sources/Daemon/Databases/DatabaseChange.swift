import Core
import Foundation

// What an agent's change does to its rows (`RowChange`), read from the rows its trial returned: the card that asks
// shows it. Once it has run, History keeps it with the rows the change itself wrote, and Undo puts those back.

extension Databases {
    /// UPDATE, DELETE or INSERT of one table where the engine says the rows it changed (RETURNING); nil for anything
    /// else. An INSERT that may write over a row (ON CONFLICT, OR REPLACE) is no insert to undo: nil too.
    /// Nor is one with a RETURNING of its own: its rows may leave columns out, and what's left out can't be put back.
    static func kind(_ sql: String, _ engine: DatabaseInfo.Engine) -> RowChange.Kind? {
        guard [.sqlite, .postgres, .duckdb].contains(engine), SQLText.returning(sql) != nil else { return nil }
        switch SQLText.verb(sql) {
        case "UPDATE": return .update
        case "DELETE": return .delete
        case "INSERT":
            let over = #"\b(ON\s+CONFLICT|OR\s+(REPLACE|IGNORE|ROLLBACK|ABORT|FAIL))\b"#
            let writesOver = SQLText.code(sql).range(of: over, options: [.regularExpression, .caseInsensitive]) != nil
            return writesOver ? nil : .insert
        default: return nil
        }
    }

    /// What `sql` does to the rows its trial returned, when Kelp has every one of them as it is: not past what a
    /// result keeps, no value shown as something else (a blob as its size). An update's rows as they were are read
    /// by the table's key: the trial is rolled back, so they're still so.
    func rowChange(_ databaseConnection: DatabaseConnection, _ sql: String, _ tried: DatabaseRows) async -> RowChange? {
        guard let kind = Self.kind(sql, databaseConnection.database.engine),
            let table = Self.table(sql, asWritten: true),
            !tried.rows.isEmpty, tried.rows.count == tried.total, !tried.opaque
        else { return nil }
        var change = RowChange(kind: kind, table: table)
        let key = await key(databaseConnection, table)
        guard !key.isEmpty, key.allSatisfy(tried.columns.contains) else { return change }
        change.key = key
        if kind == .update { change.before = await before(databaseConnection, table, key, tried) }
        return change
    }

    /// The table's primary key, by its columns' names; none when it has none or the engine doesn't say.
    private func key(_ databaseConnection: DatabaseConnection, _ table: String) async -> [String] {
        let engine = databaseConnection.database.engine
        let plain = table.filter { !"\"`".contains($0) }
        let asked: String
        switch engine {
        case .sqlite, .duckdb:
            // "main.orders": the table's own name is its last part
            let name = plain.split(separator: ".").last.map(String.init) ?? plain
            asked = "SELECT name FROM pragma_table_info(\(engine.literal(name))) WHERE pk ORDER BY cid"
        case .postgres:
            asked =
                "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid "
                + "AND a.attnum = ANY(i.indkey) WHERE i.indrelid = \(engine.literal(table))::regclass "
                + "AND i.indisprimary ORDER BY a.attnum"
        case .mysql, .appwrite: return []
        }
        do {
            return try await DatabaseEngines.read(databaseConnection, asked, off: offloads).rows.compactMap {
                $0.first ?? nil
            }
        } catch {
            Log.session.info("db key of \(table) in \(databaseConnection.database.name) wasn't read: \(error)")
            return []
        }
    }

    /// The rows of `tried` as they are now, found by `key`, in its order; nil unless every one is found once: a
    /// change that moves a row's key leaves none to find, and none to put back.
    private func before(
        _ databaseConnection: DatabaseConnection, _ table: String, _ key: [String], _ tried: DatabaseRows
    ) async
        -> [[String?]]?
    {
        let engine = databaseConnection.database.engine
        let at = key.compactMap(tried.columns.firstIndex(of:))
        let keys = tried.rows.map { row in at.map { row.indices.contains($0) ? row[$0] : nil } }
        guard at.count == key.count, keys.allSatisfy({ !$0.contains(nil) }), Set(keys).count == keys.count else {
            return nil
        }
        let found = keys.map { values in
            "(" + zip(key, values).map { "\(engine.quoted($0)) = \(engine.literal($1))" }.joined(separator: " AND ")
                + ")"
        }
        let columns = tried.columns.map(engine.quoted).joined(separator: ", ")
        let asked = "SELECT \(columns) FROM \(table) WHERE " + found.joined(separator: " OR ")
        do {
            let now = try await DatabaseEngines.read(databaseConnection, asked, off: offloads)
            guard now.rows.count == keys.count, !now.opaque else { return nil }
            let byKey = Dictionary(now.rows.map { row in (at.map { row[$0] }, row) }, uniquingKeysWith: { a, _ in a })
            let rows = keys.compactMap { byKey[$0] }
            return rows.count == keys.count ? rows : nil
        } catch {
            Log.session.info(
                "db rows of \(table) in \(databaseConnection.database.name) before a change weren't read: \(error)")
            return nil
        }
    }

    /// The statement an agent's change runs as after its trial (`tried`, as it was kept): saying its rows itself
    /// (RETURNING *) where the trial did, so the rows it's answered and kept with are the ones it wrote. The trial's
    /// aren't: a value made as it runs (a sequence's next id, now(), random()) is another the next time. As it is
    /// where the trial gave no rows (a Postgres view RETURNING doesn't fit) or it says them already; DuckDB's write
    /// asks for them itself, and the other engines have no RETURNING.
    /// Limit: rows past what Kelp reads of an answer (32 MB) fail the call though the change is made, as a
    /// statement's own RETURNING does: only rows that outgrew the trial's, which fit.
    static func saying(_ sql: String, _ engine: DatabaseInfo.Engine, tried: QueryResult?) -> String {
        guard [.sqlite, .postgres].contains(engine), tried?.columns.isEmpty == false else { return sql }
        return SQLText.returning(sql) ?? sql
    }

    /// What the trial said the change does (`tried.change`), for the rows it then wrote: an update's rows as they
    /// were are found again by the key, since the written rows needn't be the trial's, nor in its order (the table
    /// can have changed since). nil unless Kelp has every written row as it is, as `rowChange` asks of a trial's;
    /// no rows as they were unless each written row has one.
    static func written(_ tried: QueryResult, _ rows: DatabaseRows) -> RowChange? {
        guard var change = tried.change, rows.columns == tried.columns, !rows.rows.isEmpty,
            rows.rows.count == rows.total, !rows.opaque
        else { return nil }
        if let before = change.before {
            let at = change.key.compactMap(rows.columns.firstIndex(of:))
            let key = { (row: [String?]) in at.map { row.indices.contains($0) ? row[$0] : nil } }
            let was = Dictionary(zip(tried.rows.map(key), before), uniquingKeysWith: { first, _ in first })
            let found = rows.rows.compactMap { was[key($0)] }
            change.before = found.count == rows.rows.count ? found : nil
        }
        return change
    }

    /// A change's rows as they're kept (its trial's, then the ones it wrote), with what the change does to them when
    /// they're kept whole: a cell cut or a row left out for its size, and there's no saying what to put back.
    static func kept(_ rows: DatabaseRows, id: String, change: RowChange?, ms: Int = 0) -> QueryResult {
        let whole = QueryResult(
            id: id, columns: rows.columns, rows: rows.rows, total: rows.total, changed: rows.changed, ms: ms)
        var kept = trimmed(whole)
        guard var change, kept.rows == whole.rows else { return kept }
        if let before = change.before {
            var was = whole
            was.rows = before
            if trimmed(was).rows != before { change.before = nil }
        }
        kept.change = change
        return kept
    }
}
