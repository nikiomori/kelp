import Core
import Foundation

// Reads, writes and schema for MySQL inside a compose container, through the mysql batch client.

/// Runs statements through the mysql client inside a compose container (`docker exec`) and parses its batch output.
struct MySQLRun: DatabaseRunner {
    let connection: DatabaseConnection, off: Slots
    static let marker = "kelp_7f3e9c"

    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        return try await off.run {
            // The server enforces the limit too, because a client killed in a container leaves its query running there
            let out = try Self.run(
                connection, Self.limit(timeout) + ["START TRANSACTION READ ONLY", sql], timeout: timeout + 5)
            return Self.section(out.last ?? "")
        }
    }

    /// Statements that set the session's time limit for a read. MySQL calls it max_execution_time (in ms) and MariaDB
    /// max_statement_time (in s), and each refuses the other's name, so the server itself picks the one it has.
    static func limit(_ timeout: TimeInterval) -> [String] {
        let seconds = Int(timeout)
        return [
            "SET @kelp_limit = IF(VERSION() LIKE '%MariaDB%', 'SET SESSION max_statement_time = \(seconds)', "
                + "'SET SESSION max_execution_time = \(seconds * 1000)')",
            "PREPARE kelp_limit FROM @kelp_limit", "EXECUTE kelp_limit", "DEALLOCATE PREPARE kelp_limit"
        ]
    }

    /// Counts the tables a ROLLBACK can't undo (MyISAM, MEMORY, Aria, CSV…). When there are any, a change isn't
    /// tried, because the trial would really make it.
    static let unrollable = """
        SELECT COUNT(*) FROM information_schema.tables WHERE table_type = 'BASE TABLE'
          AND table_schema NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
          AND engine NOT IN ('InnoDB', 'NDB', 'ndbcluster', 'RocksDB', 'TokuDB')
        """
    static let cantRollBack = DatabaseFailure.failed("some of its tables (MyISAM, MEMORY…) can't roll back")

    func trial(_ sql: String) async throws -> DatabaseRows {
        return try await off.run {
            let tables = try Self.run(connection, [Self.unrollable], timeout: DatabaseEngines.readTimeout + 5)
            guard (Self.section(tables.last ?? "").rows.first?.first ?? nil) == "0" else { throw Self.cantRollBack }
            let out = try Self.run(connection, ["START TRANSACTION", Self.counted(sql), "ROLLBACK"], timeout: 60)
            guard out.count >= 2 else { throw DatabaseFailure.failed("mysql said nothing of the change.") }
            return Self.withCount(out[out.count - 2])
        }
    }

    /// Handles `allowed` as the wire runner does (`MySQLWire.write`), within the client's one session. The server
    /// itself commits or rolls back by the row count it kept for the statement. It does so with a prepared COMMIT or
    /// ROLLBACK, because the mysql client has no `if`.
    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows {
        return try await off.run {
            guard let allowed else {
                let out = try Self.run(connection, [Self.counted(sql)], timeout: DatabaseEngines.writeTimeout + 10)
                return out.last.map(Self.withCount) ?? DatabaseRows()
            }
            let decide = [
                "SET @kelp_end = IF(@kelp_changed = \(allowed), 'COMMIT', 'ROLLBACK')",
                "PREPARE kelp_end FROM @kelp_end",
                "EXECUTE kelp_end", "SELECT @kelp_changed = \(allowed) AS kelp_held"
            ]
            let kept = sql + "\n;\nSET @kelp_changed = ROW_COUNT();\nSELECT @kelp_changed AS " + Self.changedColumn
            let out = try Self.run(
                connection, ["START TRANSACTION", kept] + decide, timeout: DatabaseEngines.writeTimeout + 10)
            guard out.count == 6 else { throw DatabaseFailure.failed("mysql said nothing of the change.") }
            let rows = Self.withCount(out[1])
            guard Self.section(out[5]).rows.first?.first == "1" else {
                throw DatabaseEngines.notAsAllowed(rows.changed, allowed)
            }
            return rows
        }
    }

    /// Runs the edits as one script. mysql stops at the first error (no --force), so COMMIT never runs and the
    /// session rolls back.
    func apply(_ statements: [String]) async throws -> Int {
        return try await off.run {
            let out = try Self.run(
                connection, ["START TRANSACTION"] + statements.map(Self.counted) + ["COMMIT"],
                timeout: DatabaseEngines.writeTimeout + 10)
            return out.dropFirst().dropLast().map { Self.withCount($0).changed ?? 0 }.reduce(0, +)
        }
    }

    /// The column that holds the rows a statement changed. The count is read right after the statement, because any
    /// statement in between would reset it.
    static let changedColumn = "kelp_changed"
    /// Follows the statement with a read of the rows it changed. The statement's `;` goes on a line of its own,
    /// because its last line can be a `--` comment.
    static func counted(_ sql: String) -> String { sql + "\n;\nSELECT ROW_COUNT() AS " + changedColumn }

    /// Parses what `counted` printed: the statement's rows, if any, then a table that holds one count.
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

    func schema() async throws -> DatabaseSchema {
        return try await off.run {
            let out = try Self.run(
                connection, [Self.schemaColumns, Self.schemaCounts, Self.schemaIndexes],
                timeout: DatabaseEngines.readTimeout + 10)
            guard out.count >= 3 else { throw DatabaseFailure.failed("mysql said nothing of the tables.") }
            return DatabaseSchemaBuilder.build(
                columns: Self.section(out[out.count - 3]).rows, counts: Self.section(out[out.count - 2]).rows,
                indexes: Self.section(out[out.count - 1]).rows)
        }
    }

    /// Runs the statements as one script on stdin, with a marker after each one. Binary mode turns off client
    /// commands such as `system`.
    static func run(_ databaseConnection: DatabaseConnection, _ statements: [String], timeout: TimeInterval) throws
        -> [String]
    {
        let db = databaseConnection.database
        let (client, host, port) = try DatabaseEngines.invocation(databaseConnection, "mysql", pass: ["MYSQL_PWD"])
        // To mysql, localhost means the Unix socket, so the server's port is reached by its address.
        var argv =
            Array(client.dropLast()) + Self.client
            + ["--batch", "--binary-mode", "-h", host == "localhost" ? "127.0.0.1" : host, "-P", String(port)]
        if let user = db.user { argv += ["-u", user] }
        if let name = db.database { argv.append(name) }
        let script = Self.script(statements)
        let env = DatabaseEngines.environment(["MYSQL_PWD": databaseConnection.password])
        let out = try program(argv, env: env, script: script, timeout: timeout)
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

    /// Runs mysql in the container. A Stop ends only the docker client, while mysql and its statement go on in the
    /// container (the server has nothing to find that connection by and KILL it), so the call says that, not Stopped.
    static func program(_ argv: [String], env: [String: String], script: String, timeout: TimeInterval) throws
        -> Subprocess.Output
    {
        DatabaseStop.current?.leaves(leftRunning)
        return try DatabaseStop.program(argv, env: env, stdin: Data(script.utf8), timeLimit: timeout)
    }
    static let leftRunning =
        "Stopped waiting. The statement may still run to its end in the container, and keep what it changes."

    /// The client in the container: mysql, or mariadb where only that is there (MariaDB 11's images). The shell's
    /// `$@` is the client's arguments.
    static let client = ["sh", "-c", #"exec "$(command -v mysql || command -v mariadb || echo mysql)" "$@""#, "mysql"]

    /// The statements with a marker after each. A statement's `;` goes on a line of its own, because its last line can
    /// be a `--` comment.
    static func script(_ statements: [String]) -> String {
        statements.map { $0 + "\n;\nSELECT '\(marker)' AS \(marker);\n" }.joined()
    }

    /// Parses tab-separated output with a header first. Tabs, newlines and backslashes arrive escaped (\t \n \\), and
    /// NULL arrives as NULL. A row of one empty value is an empty line.
    static func section(_ text: String) -> DatabaseRows {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
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
