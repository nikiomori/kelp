import Core
import Foundation

// Postgres inside a compose container: psql's reads, writes and schema.

enum PostgresRun {
    /// Between a command's output and the next: what psql prints for `\echo`.
    static let marker = "--kelp-7f3e9c--"
    /// What psql writes for NULL: its CSV writes an empty string and NULL alike, as an empty field.
    static let null = "\u{1}NULL\u{1}"

    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval) throws -> DatabaseRows {
        let out = try run(
            c, ["BEGIN TRANSACTION READ ONLY", "SET LOCAL statement_timeout = '\(Int(timeout))s'", sql],
            timeout: timeout + 10)
        return section(out.last ?? "")
    }

    static func trial(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        func attempt(_ statement: String) throws -> DatabaseRows {
            let out = try run(
                c,
                [
                    "BEGIN", "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'", statement,
                    "ROLLBACK"
                ],
                timeout: DatabaseEngines.readTimeout + 10)
            var rows = section(out.count >= 2 ? out[out.count - 2] : "")
            if rows.changed == nil { rows.changed = rows.total }   // RETURNING: the rows are what it changed
            return rows
        }
        if let returning = SQLText.returning(sql) {
            do { return try attempt(returning) } catch {}   // RETURNING may not fit it (a MERGE, a view): tried plain
        }
        return try attempt(sql)
    }

    /// `allowed`: as over the wire (`PostgresWire.write`), in psql's one session: the ROW_COUNT psql keeps of the
    /// statement picks COMMIT or ROLLBACK. That choice is a script of Kelp's own on stdin; the statement still goes as
    /// `-c`, which psql sends as it is, never reading its own commands in it.
    static func write(_ c: DatabaseConnection, _ sql: String, allowed: Int? = nil) throws -> DatabaseRows {
        let limit = "statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'"
        guard let allowed else {
            let out = try run(c, ["SET " + limit, sql], timeout: DatabaseEngines.writeTimeout + 10)
            return section(out.last ?? "")
        }
        let decide = """
            \\echo \(marker)
            SELECT :ROW_COUNT = \(allowed) AS kelp_held \\gset
            \\if :kelp_held
            COMMIT;
            \\else
            ROLLBACK;
            \\endif
            """
        let out = try run(
            c, ["BEGIN", "SET LOCAL " + limit, sql], then: decide, timeout: DatabaseEngines.writeTimeout + 10)
        let rows = section(out.count >= 2 ? out[out.count - 2] : "")
        guard out.last?.hasPrefix("COMMIT") == true else { throw DatabaseEngines.notAsAllowed(rows.changed, allowed) }
        return rows
    }

    /// BEGIN, the statements, COMMIT: ON_ERROR_STOP ends psql at the first failure, its session rolling back.
    static func apply(_ c: DatabaseConnection, _ statements: [String]) throws -> Int {
        let out = try run(c, ["BEGIN"] + statements + ["COMMIT"], timeout: DatabaseEngines.writeTimeout + 10)
        return out.dropLast().map { section($0).changed ?? 0 }.reduce(0, +)
    }

    private static let other = "NOT IN ('pg_catalog', 'information_schema', 'pg_toast')"
    static let schemaColumns = """
        SELECT CASE WHEN c.table_schema = 'public' THEN c.table_name ELSE c.table_schema || '.' || c.table_name END,
          c.column_name, c.data_type, c.is_nullable,
          EXISTS (SELECT 1 FROM information_schema.table_constraints t JOIN information_schema.key_column_usage k
            ON k.constraint_name = t.constraint_name AND k.table_schema = t.table_schema
            WHERE t.constraint_type = 'PRIMARY KEY' AND t.table_schema = c.table_schema
            AND t.table_name = c.table_name AND k.column_name = c.column_name),
          (SELECT u.table_name || '.' || u.column_name FROM information_schema.table_constraints t
            JOIN information_schema.key_column_usage k ON k.constraint_name = t.constraint_name
              AND k.table_schema = t.table_schema
            JOIN information_schema.constraint_column_usage u ON u.constraint_name = t.constraint_name
              AND u.constraint_schema = t.table_schema
            WHERE t.constraint_type = 'FOREIGN KEY' AND t.table_schema = c.table_schema
            AND t.table_name = c.table_name AND k.column_name = c.column_name LIMIT 1)
        FROM information_schema.columns c WHERE c.table_schema \(other)
        ORDER BY c.table_schema, c.table_name, c.ordinal_position
        """
    static let schemaCounts = """
        SELECT CASE WHEN n.nspname = 'public' THEN c.relname ELSE n.nspname || '.' || c.relname END,
          CASE WHEN c.reltuples < 0 THEN s.n_live_tup ELSE c.reltuples::bigint END,   -- -1: never analyzed
          CASE WHEN c.relkind IN ('v', 'm') THEN 'view' END, pg_total_relation_size(c.oid),
          obj_description(c.oid, 'pg_class')
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
        WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname \(other)
        """
    static let schemaFunctions = """
        SELECT DISTINCT CASE WHEN n.nspname = 'public' THEN p.proname ELSE n.nspname || '.' || p.proname END
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname \(other) AND p.prokind = 'f'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
        ORDER BY 1
        """
    /// The database's own functions: not an extension's (PostGIS alone puts hundreds in public).
    static let schemaIndexes = """
        SELECT CASE WHEN schemaname = 'public' THEN tablename ELSE schemaname || '.' || tablename END,
          indexname || ' ' || substring(indexdef from '\\((.*)\\)$')
        FROM pg_indexes WHERE schemaname \(other) ORDER BY indexname
        """
    static func schema(_ c: DatabaseConnection) throws -> DatabaseSchema {
        let out = try run(
            c, ["BEGIN TRANSACTION READ ONLY", schemaColumns, schemaCounts, schemaIndexes],
            timeout: DatabaseEngines.readTimeout + 10)
        guard out.count >= 3 else { throw DatabaseFailure.failed("psql said nothing of the tables.") }
        return DatabaseSchemaBuilder.build(
            columns: section(out[out.count - 3]).rows, counts: section(out[out.count - 2]).rows,
            indexes: section(out[out.count - 1]).rows)
    }

    /// Each command's output after the first (BEGIN's), split at the markers psql echoes between them. `script`: psql's
    /// own commands of Kelp's, run after them in the same session (stdin).
    static func run(
        _ c: DatabaseConnection, _ commands: [String], then script: String? = nil, timeout: TimeInterval
    ) throws -> [String] {
        let db = c.database
        let (client, host, port) = try DatabaseEngines.invocation(c, "psql", secret: "PGPASSWORD")
        var argv =
            client + [
                "-X", "-w", "--csv", "-P", "null=" + null, "-v", "ON_ERROR_STOP=1", "-h", host, "-p", String(port),
                "-d",
                db.database ?? "postgres"
            ]
        if let user = db.user { argv += ["-U", user] }
        for (index, command) in commands.enumerated() {
            if index > 0 { argv += ["-c", "\\echo " + marker] }
            argv += ["-c", command]
        }
        if script != nil { argv += ["-f", "-"] }
        let env = DatabaseEngines.environment([
            // UTC as over the wire (`PostgresText`): a row found by its values compares the same text
            "PGCONNECT_TIMEOUT": "5", "PGAPPNAME": "kelp", "PGPASSWORD": c.password, "PGTZ": "UTC"
        ])
        let out = try Subprocess.run(
            argv, cwd: NSHomeDirectory(), env: env, stdin: script.map { Data($0.utf8) }, timeLimit: timeout,
            limit: DatabaseEngines.outputLimit)
        guard out.status == 0, !out.timedOut else {
            if out.timedOut { throw DatabaseFailure.failed("No answer from \(db.name) in \(Int(timeout)) s.") }
            throw failure(String(decoding: out.stderr, as: UTF8.self))
        }
        try DatabaseEngines.whole(out, db.name)
        return String(decoding: out.stdout, as: UTF8.self).components(separatedBy: marker + "\n").dropFirst().map {
            $0
        }
    }

    /// psql's error: a change refused in a read-only transaction, or the server's own words.
    static func failure(_ stderr: String) -> DatabaseFailure {
        if stderr.contains("read-only transaction") { return .change }
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        if let error = lines.first(where: { $0.hasPrefix("ERROR:") }) {
            return .failed(error.replacingOccurrences(of: "ERROR:  ", with: "").trimmingCharacters(in: .whitespaces))
        }
        // Connecting, psql tries each address (::1, then 127.0.0.1) and says why each failed: the last is the one that
        // got furthest ("no password supplied" after a refused ::1).
        let tries = lines.filter { $0.contains(" failed: ") }
        if let last = tries.last, let reason = last.range(of: " failed: ") {
            return .failed(String(last[reason.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        let text =
            (lines.first { $0.hasPrefix("psql: error:") || $0.hasPrefix("FATAL:") } ?? lines.first ?? "psql failed")
            .replacingOccurrences(of: "psql: error: ", with: "")
        return .failed(text.trimmingCharacters(in: .whitespaces))
    }

    /// One command's output: rows as CSV (a header, then rows; NULL written as `null`), or the command's tag
    /// ("UPDATE 3"), whose number is what it changed; a change with RETURNING gives both, its tag last.
    static func section(_ text: String) -> DatabaseRows {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        var changed: Int?
        if lines.count > 1, let last = lines.last,
            last.range(of: #"^(INSERT \d+ \d+|UPDATE \d+|DELETE \d+|MERGE \d+)$"#, options: .regularExpression) != nil
        {
            changed = last.split(separator: " ").last.flatMap { Int($0) }
            lines.removeLast()
        }
        var rows = table(lines.joined(separator: "\n"))
        rows.changed = rows.changed ?? changed
        return rows
    }

    private static func table(_ text: String) -> DatabaseRows {
        let body = text.split(separator: "\n", omittingEmptySubsequences: false)
        if body.count == 1, let tag = body.first,
            tag.range(of: #"^[A-Z]+( [A-Z]+)*( \d+)*$"#, options: .regularExpression) != nil
        {
            return DatabaseRows(changed: tag.split(separator: " ").last.flatMap { Int($0) })
        }
        var records = CSV.parse(text)
        guard !records.isEmpty else { return DatabaseRows() }
        let header = records.removeFirst().map { $0 ?? "" }
        let rows = records.prefix(DatabaseEngines.keep).map { row in row.map { $0 == null ? nil : $0 ?? "" } }
        return DatabaseRows(columns: header, rows: rows, total: records.count)
    }
}
