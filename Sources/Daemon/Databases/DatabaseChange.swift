import Core
import Foundation

// Works out what an agent's change does to the rows it touches (`RowChange`), from the rows its trial returned. The
// card that asks the user shows this. Once the change has run, History keeps the RowChange with the rows the change
// itself wrote, and Undo uses it to put the rows back.

extension Databases {
    /// Returns the kind of an UPDATE, DELETE or INSERT on an engine that can report the rows it changed (RETURNING),
    /// and nil for anything else. An INSERT that may write over a row (ON CONFLICT, OR REPLACE) is not a plain insert
    /// that Undo can remove, so it gets nil too. So does a statement with a RETURNING of its own, because its rows may
    /// leave columns out, and a column left out can't be put back.
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

    /// Returns what `sql` does to the rows its trial returned, when Kelp has every one of those rows as it is. That
    /// means no row past what a result keeps, and no value shown as something else (a blob as its size). For an
    /// update, the rows as they were are read by the table's key, because the trial was rolled back and the table
    /// still holds them.
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

    /// Returns the column names of the table's primary key, or none when the table has none or the engine doesn't say.
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

    /// Reads the rows of `tried` as they are now, found by `key`, in the order of `tried`. Returns nil unless every
    /// row is found exactly once, because a change that moves a row's key leaves no row to find and none to put back.
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
        let columns = tried.columns.map(engine.quoted).joined(separator: ", ")
        do {
            var read: [[String?]] = []
            for asked in Self.reads(of: keys, by: key, columns: columns, from: table, engine) {
                let now = try await DatabaseEngines.read(databaseConnection, asked, off: offloads)
                guard !now.opaque else { return nil }
                read += now.rows
            }
            guard read.count == keys.count else { return nil }
            let byKey = Dictionary(read.map { row in (at.map { row[$0] }, row) }, uniquingKeysWith: { a, _ in a })
            let rows = keys.compactMap { byKey[$0] }
            return rows.count == keys.count ? rows : nil
        } catch {
            Log.session.info(
                "db rows of \(table) in \(databaseConnection.database.name) before a change weren't read: \(error)")
            return nil
        }
    }

    /// The reads that find rows by their keys, a few hundred keys each: SQLite refuses an expression deeper than 1000,
    /// and one OR per row of a change to every row of a table would be deeper.
    static func reads(
        of keys: [[String?]], by key: [String], columns: String, from table: String, _ engine: DatabaseInfo.Engine
    ) -> [String] {
        stride(from: 0, to: keys.count, by: 400).map { start in
            let found = keys[start..<min(start + 400, keys.count)].map { values in
                "(" + zip(key, values).map { "\(engine.quoted($0)) = \(engine.literal($1))" }.joined(separator: " AND ")
                    + ")"
            }
            return "SELECT \(columns) FROM \(table) WHERE " + found.joined(separator: " OR ")
        }
    }

    /// Returns the statement that an agent's change runs after its trial (`tried`, as the trial was kept). When the
    /// trial returned rows, the statement returns its own rows (RETURNING *), so the rows the agent gets back and Kelp
    /// keeps are the ones this run wrote. The trial's rows can't be used, because a value made while the statement
    /// runs (a sequence's next id, now(), random()) differs the next time. The statement is left as it is when the
    /// trial returned no rows (RETURNING doesn't fit a Postgres view) or when it already returns rows. DuckDB's write
    /// asks for the rows itself, and the other engines have no RETURNING.
    /// Limit: if the rows are more than Kelp reads of an answer (32 MB), the call fails even though the change is made,
    /// the same as a statement's own RETURNING would. Only rows that outgrew the trial's rows can do that, because the
    /// trial's rows fit.
    static func saying(_ sql: String, _ engine: DatabaseInfo.Engine, tried: QueryResult?) -> String {
        guard [.sqlite, .postgres].contains(engine), tried?.columns.isEmpty == false else { return sql }
        return SQLText.returning(sql) ?? sql
    }

    /// Applies what the trial said the change does (`tried.change`) to the rows the change then wrote. An update's old
    /// rows are found again by the key, because the written rows need not be the trial's rows or in the same order (the
    /// table may have changed since). Returns nil unless Kelp has every written row in full, as `rowChange` requires of
    /// a trial's rows. The result keeps old rows only when every written row has one.
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

    /// Returns a change's rows as Kelp keeps them (first the trial's rows, later the rows the change wrote). It adds
    /// what the change does to them only when the rows are kept whole, because if a cell was cut or a row left out for
    /// its size, Kelp can't say what to put back.
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
