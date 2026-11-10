import Core
import Foundation

// MySQL inside a compose container: its batch client's reads, writes and schema.

/// mysql inside a compose container (`docker exec`): its batch output.
struct MySQLRun: Sendable {
    let c: DatabaseConnection, off: Slots
    static let marker = "kelp_7f3e9c"

    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval) throws -> DatabaseRows {
        // The server stops it too: a client killed in a container (`docker exec`) leaves its query running there
        let out = try run(c, limit(timeout) + ["START TRANSACTION READ ONLY", sql], timeout: timeout + 5)
        return section(out.last ?? "")
    }

    /// The session's time limit for a read: MySQL names it max_execution_time (ms), MariaDB max_statement_time (s),
    /// and each refuses the other's name, so the one this server has is picked by the server.
    static func limit(_ timeout: TimeInterval) -> [String] {
        let seconds = Int(timeout)
        return [
            "SET @kelp_limit = IF(VERSION() LIKE '%MariaDB%', 'SET SESSION max_statement_time = \(seconds)', "
                + "'SET SESSION max_execution_time = \(seconds * 1000)')",
            "PREPARE kelp_limit FROM @kelp_limit", "EXECUTE kelp_limit", "DEALLOCATE PREPARE kelp_limit"
        ]
    }

    /// Tables a ROLLBACK can't undo (MyISAM, MEMORY, Aria, CSV…): with any, a change isn't tried, since the trial
    /// would make it.
    static let unrollable = """
        SELECT COUNT(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE'
          AND table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
          AND engine NOT IN ('InnoDB', 'NDB', 'ndbcluster', 'RocksDB', 'TokuDB')
        """
    static let cantRollBack = DatabaseFailure.failed("some of its tables (MyISAM, MEMORY…) can't roll back")

    static func trial(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let tables = try run(c, [unrollable], timeout: DatabaseEngines.readTimeout + 5)
        guard (section(tables.last ?? "").rows.first?.first ?? nil) == "0" else { throw cantRollBack }
        let out = try run(c, ["START TRANSACTION", counted(sql), "ROLLBACK"], timeout: 60)
        guard out.count >= 2 else { throw DatabaseFailure.failed("mysql said nothing of the change.") }
        return withCount(out[out.count - 2])
    }

    /// `allowed`: as over the wire (`MySQLWire.write`), in the client's one session: the server itself commits or rolls
    /// back by the count it kept of the statement (a prepared COMMIT or ROLLBACK, as the mysql client has no `if`).
    static func write(_ c: DatabaseConnection, _ sql: String, allowed: Int? = nil) throws -> DatabaseRows {
        guard let allowed else {
            let out = try run(c, [counted(sql)], timeout: DatabaseEngines.writeTimeout + 10)
            return out.last.map(withCount) ?? DatabaseRows()
        }
        let decide = [
            "SET @kelp_end = IF(@kelp_changed = \(allowed), 'COMMIT', 'ROLLBACK')", "PREPARE kelp_end FROM @kelp_end",
            "EXECUTE kelp_end", "SELECT @kelp_changed = \(allowed) AS kelp_held"
        ]
        let kept = sql + "\n;\nSET @kelp_changed = ROW_COUNT();\nSELECT @kelp_changed AS " + changedColumn
        let out = try run(c, ["START TRANSACTION", kept] + decide, timeout: DatabaseEngines.writeTimeout + 10)
        guard out.count == 6 else { throw DatabaseFailure.failed("mysql said nothing of the change.") }
        let rows = withCount(out[1])
        guard section(out[5]).rows.first?.first == "1" else {
            throw DatabaseEngines.notAsAllowed(rows.changed, allowed)
        }
        return rows
    }

    /// One script: mysql stops at the first error (no --force), so COMMIT never comes and its session rolls back.
    static func apply(_ c: DatabaseConnection, _ statements: [String]) throws -> Int {
        let out = try run(
            c, ["START TRANSACTION"] + statements.map(counted) + ["COMMIT"], timeout: DatabaseEngines.writeTimeout + 10)
        return out.dropFirst().dropLast().map { withCount($0).changed ?? 0 }.reduce(0, +)
    }

    /// The statement and, right after it (anything between would reset it), the rows it changed.
    static let changedColumn = "kelp_changed"
    /// Its `;` on a line of its own: a statement's last line can be a `--` comment.
    static func counted(_ sql: String) -> String { sql + "\n;\nSELECT ROW_COUNT() AS " + changedColumn }

    /// What `counted` printed: the statement's rows, if any, then a table of one count.
    static func withCount(_ text: String) -> DatabaseRows {
        guard let count = text.range(of: changedColumn + "\n", options: .backwards) else { return section(text) }
        var rows = section(String(text[..<count.lowerBound]))
        rows.changed = Int(text[count.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        return rows
    }

    private static let here = "table_schema = DATABASE()"
    static let schemaColumns = """
        SELECT c.table_name, c.column_name, c.column_type, c.is_nullable, c.column_key = 'PRI',
          (SELECT CONCAT(k.referenced_table_name, '.', k.referenced_column_name)
           FROM information_schema.key_column_usage k
           WHERE k.table_schema = c.table_schema AND k.table_name = c.table_name AND k.column_name = c.column_name
           AND k.referenced_table_name IS NOT NULL LIMIT 1)
        FROM information_schema.columns c WHERE c.\(here) ORDER BY c.table_name, c.ordinal_position
        """
    static let schemaCounts = """
        SELECT table_name, table_rows, CASE WHEN table_type = 'VIEW' THEN 'view' END, data_length + index_length,
          NULLIF(table_comment, '')
        FROM information_schema.tables WHERE \(here)
        """
    static let schemaFunctions =
        "SELECT routine_name FROM information_schema.routines WHERE routine_schema = DATABASE()"
    static let schemaIndexes = """
        SELECT table_name, CONCAT(index_name, ' (', GROUP_CONCAT(column_name ORDER BY seq_in_index), ')')
        FROM information_schema.statistics WHERE \(here) GROUP BY table_name, index_name
        """

    static func schema(_ c: DatabaseConnection) throws -> DatabaseSchema {
        let out = try run(c, [schemaColumns, schemaCounts, schemaIndexes], timeout: DatabaseEngines.readTimeout + 10)
        guard out.count >= 3 else { throw DatabaseFailure.failed("mysql said nothing of the tables.") }
        return DatabaseSchemaBuilder.build(
            columns: section(out[out.count - 3]).rows, counts: section(out[out.count - 2]).rows,
            indexes: section(out[out.count - 1]).rows)
    }

    /// The statements as one script on stdin, in binary mode (no client commands such as `system`), a marker between
    /// them.
    static func run(_ c: DatabaseConnection, _ statements: [String], timeout: TimeInterval) throws -> [String] {
        let db = c.database
        let (client, host, port) = try DatabaseEngines.invocation(c, "mysql", secret: "MYSQL_PWD")
        // localhost would mean its Unix socket to mysql: the server's port is asked for by address.
        var argv =
            client + ["--batch", "--binary-mode", "-h", host == "localhost" ? "127.0.0.1" : host, "-P", String(port)]
        if let user = db.user { argv += ["-u", user] }
        if let name = db.database { argv.append(name) }
        let script = statements.map { $0 + ";\nSELECT '\(marker)' AS \(marker);\n" }.joined()
        let env = DatabaseEngines.environment(["MYSQL_PWD": c.password])
        let out = try Subprocess.run(
            argv, cwd: NSHomeDirectory(), env: env, stdin: Data(script.utf8), timeLimit: timeout,
            limit: DatabaseEngines.outputLimit)
        guard out.status == 0, !out.timedOut else {
            if out.timedOut { throw DatabaseFailure.failed("No answer from \(db.name) in \(Int(timeout)) s.") }
            let said = String(decoding: out.stderr, as: UTF8.self)
            if said.contains("READ ONLY transaction") { throw DatabaseFailure.change }
            throw DatabaseFailure.failed(
                said.split(whereSeparator: \.isNewline).first.map(String.init) ?? "mysql failed")
        }
        try DatabaseEngines.whole(out, db.name)
        return String(decoding: out.stdout, as: UTF8.self)
            .components(separatedBy: "\(marker)\n\(marker)\n").dropLast().map { $0 }
    }

    /// Tab-separated, a header first; \t \n \\ escaped, NULL written as NULL.
    static func section(_ text: String) -> DatabaseRows {
        var lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return DatabaseRows() }
        let header = lines.removeFirst().components(separatedBy: "\t")
        let rows = lines.map { line in
            line.components(separatedBy: "\t").map { field -> String? in
                field == "NULL"
                    ? nil
                    : field.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
        return DatabaseRows(columns: header, rows: Array(rows.prefix(DatabaseEngines.keep)), total: rows.count)
    }
}
