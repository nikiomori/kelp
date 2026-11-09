import Core
import Foundation

/// A DuckDB file through the `duckdb` program (Homebrew's), as CSV: NULL written as `PostgresRun.null`, so an empty
/// string stays one. A read opens the file read-only, so DuckDB refuses a change; a change counts its rows through
/// RETURNING (DuckDB prints no count of its own), tried in a transaction it rolls back.
enum DuckDBRun {
    static let marker = "--kelp-7f3e9c--"

    static func read(_ path: String, _ sql: String, timeout: TimeInterval) throws -> DatabaseRows {
        section(try run(path, readOnly: true, [sql], timeout: timeout).first ?? "")
    }

    static func trial(_ path: String, _ sql: String) throws -> DatabaseRows {
        let returning = SQLText.returning(sql)
        let out = try run(
            path, readOnly: false, ["BEGIN", returning ?? sql, "ROLLBACK"], timeout: DatabaseEngines.readTimeout)
        var rows = section(out.count > 1 ? out[1] : "")
        rows.changed = returning == nil ? nil : rows.total
        return rows
    }

    static func write(_ path: String, _ sql: String) throws -> DatabaseRows {
        let returning = SQLText.returning(sql)
        let out = try run(path, readOnly: false, [returning ?? sql], timeout: DatabaseEngines.writeTimeout)
        var rows = section(out.first ?? "")
        rows.changed = returning == nil ? nil : rows.total
        return rows
    }

    /// The user's edits in one transaction (-bail stops before COMMIT): the rows each changed, as `.changes` prints
    /// them.
    static func apply(_ path: String, _ statements: [String]) throws -> Int {
        let out = try run(
            path, readOnly: false, ["BEGIN"] + statements + ["COMMIT"], timeout: DatabaseEngines.writeTimeout,
            changes: true)
        return out.compactMap { section in
            section.firstMatch(of: /changes:\s+(\d+)/).flatMap { Int($0.1) }
        }.reduce(0, +)
    }

    static let schemaColumns = """
        SELECT c.table_name, c.column_name, c.data_type, c.is_nullable,
          EXISTS (SELECT 1 FROM duckdb_constraints() k WHERE k.table_name = c.table_name
            AND k.constraint_type = 'PRIMARY KEY' AND list_contains(k.constraint_column_names, c.column_name)),
          (SELECT k.referenced_table || '.'
              || k.referenced_column_names[list_position(k.constraint_column_names, c.column_name)]
            FROM duckdb_constraints() k WHERE k.table_name = c.table_name AND k.constraint_type = 'FOREIGN KEY'
            AND list_contains(k.constraint_column_names, c.column_name) LIMIT 1)
        FROM information_schema.columns c WHERE c.table_schema = 'main'
        ORDER BY c.table_name, c.ordinal_position
        """
    static let schemaCounts = "SELECT table_name, estimated_size FROM duckdb_tables() WHERE schema_name = 'main'"
    static let schemaIndexes = """
        SELECT table_name, index_name || ' ' || replace(replace(CAST(expressions AS VARCHAR), '[', '('), ']', ')')
        FROM duckdb_indexes() WHERE schema_name = 'main'
        """

    static func schema(_ path: String) throws -> DatabaseSchema {
        let out = try run(
            path, readOnly: true, [schemaColumns, schemaCounts, schemaIndexes], timeout: DatabaseEngines.readTimeout)
        guard out.count >= 3 else { throw DatabaseFailure.failed("duckdb said nothing of the tables.") }
        return DatabaseSchemaBuilder.build(
            columns: section(out[0]).rows, counts: section(out[1]).rows, indexes: section(out[2]).rows)
    }

    /// The statements as a script on stdin, a marker printed after each; it stops at the first error (`-bail`).
    /// `-safe`: no dot-command that reaches past the file (`.shell`, `.open`, `.read`) and no file but this one
    /// (ATTACH, COPY, read_csv), locked against a SET that would lift it; `-no-agent` keeps the CSV whatever AI_AGENT
    /// says.
    /// `changes`: each statement followed by the rows it changed ("changes: 1   total_changes: 3").
    static func run(
        _ path: String, readOnly: Bool, _ statements: [String], timeout: TimeInterval, changes: Bool = false
    ) throws -> [String] {
        let duckdb = try DatabaseEngines.client("duckdb", also: ["/opt/homebrew/bin", "/usr/local/bin"])
        let argv =
            [duckdb, "-safe", "-no-agent", "-bail", "-csv", "-nullvalue", PostgresRun.null]
            + (readOnly ? ["-readonly"] : []) + [path]
        let script = (changes ? ".changes on\n" : "") + statements.map { $0 + ";\n.print " + marker + "\n" }.joined()
        let out = try Subprocess.run(
            argv, cwd: NSHomeDirectory(), env: DatabaseEngines.environment([:]), stdin: Data(script.utf8),
            timeLimit: timeout + 5, limit: DatabaseEngines.outputLimit)
        guard out.status == 0, !out.timedOut else {
            if out.timedOut { throw DatabaseFailure.failed("duckdb took more than \(Int(timeout)) s.") }
            let said = String(decoding: out.stderr, as: UTF8.self)
            if said.contains("read-only mode") { throw DatabaseFailure.change }
            throw DatabaseFailure.failed(
                said.split(whereSeparator: \.isNewline).first.map(String.init) ?? "duckdb failed")
        }
        try DatabaseEngines.whole(out, (path as NSString).lastPathComponent)
        return String(decoding: out.stdout, as: UTF8.self).components(separatedBy: marker + "\n").dropLast().map {
            $0
        }
    }

    /// CSV with a header; NULL is the marker (quoted), an empty field an empty string.
    static func section(_ text: String) -> DatabaseRows {
        var records = CSV.parse(text)
        guard !records.isEmpty else { return DatabaseRows() }
        let header = records.removeFirst().map { $0 ?? "" }
        let rows = records.prefix(DatabaseEngines.keep).map { row in
            row.map { $0 == PostgresRun.null ? nil : $0 ?? "" }
        }
        return DatabaseRows(columns: header, rows: Array(rows), total: records.count)
    }
}
