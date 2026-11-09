import Core
import Foundation
import GRDB

/// A database and the password that opens it, as kelpd holds them: never sent to a client.
struct DatabaseConnection: Sendable {
    var database: DatabaseInfo
    var password: String?
}

/// What a statement gave: its columns and rows (nil for NULL), `total` counted past what's kept up to `countLimit`.
struct DatabaseRows: Equatable, Sendable {
    var columns: [String] = []
    var rows: [[String?]] = []
    var total = 0
    var changed: Int?
}

/// Runs statements on a database: SQLite in kelpd (GRDB), Postgres and MySQL through their own clients (`psql`,
/// `mysql`), found on the login PATH or where Homebrew and Postgres.app keep them. A read runs in a read-only
/// transaction (a read-only file for SQLite), so the database itself refuses a change; a trial runs a change and rolls
/// it
/// back; a write runs it on its own. One statement each (`SQLText.single`).
enum DatabaseEngines {
    /// Rows kept of a result; more are counted up to `countLimit`.
    static let keep = 1000, countLimit = 100_000
    /// A read's time limit, and a change's.
    static let readTimeout: TimeInterval = 15, writeTimeout: TimeInterval = 300

    static func read(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        switch c.database.engine {
        case .sqlite: try SQLiteRun.read(path(c), sql)
        case .postgres: try PostgresRun.read(c, sql)
        case .mysql: try MySQLRun.read(c, sql)
        }
    }

    /// The change made and rolled back: what it touched, and the rows it would leave when it can say (RETURNING).
    static func trial(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        switch c.database.engine {
        case .sqlite: try SQLiteRun.trial(path(c), sql)
        case .postgres: try PostgresRun.trial(c, sql)
        case .mysql: try MySQLRun.trial(c, sql)
        }
    }

    static func write(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        switch c.database.engine {
        case .sqlite: try SQLiteRun.write(path(c), sql)
        case .postgres: try PostgresRun.write(c, sql)
        case .mysql: try MySQLRun.write(c, sql)
        }
    }

    static func schema(_ c: DatabaseConnection, table: String?) throws -> DatabaseSchema {
        let schema: DatabaseSchema =
            switch c.database.engine {
            case .sqlite: try SQLiteRun.schema(path(c))
            case .postgres: try PostgresRun.schema(c)
            case .mysql: try MySQLRun.schema(c)
            }
        guard let table else { return schema }
        let one = schema.tables.filter { $0.name.caseInsensitiveCompare(table) == .orderedSame }
        guard !one.isEmpty else {
            throw DatabaseFailure.failed("No table \(table) in \(c.database.name). Its tables: kelp db schema")
        }
        return DatabaseSchema(tables: one)
    }

    private static func path(_ c: DatabaseConnection) throws -> String {
        guard let path = c.database.path, FileManager.default.fileExists(atPath: path) else {
            throw DatabaseFailure.failed("\(c.database.name)'s file isn't there: \(c.database.path ?? "no path").")
        }
        return path
    }

    /// The client program, from the login PATH or where it's usually kept (libpq is keg-only in Homebrew).
    static func client(_ name: String, also: [String]) throws -> String {
        do { return try LoginPath.resolve(name) } catch {}   // not on the PATH: where it's usually kept
        if let found = also.map({ $0 + "/" + name }).first(where: FileManager.default.isExecutableFile(atPath:)) {
            return found
        }
        let hint = name == "psql" ? "brew install libpq" : "brew install mysql-client"
        throw DatabaseFailure.failed("\(name) isn't installed, and Kelp talks to this database through it: \(hint).")
    }

    /// A value as text: numbers as SQLite gives them, a blob as its size.
    static func text(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null: nil
        case .int64(let n): String(n)
        case .double(let d): String(d)
        case .string(let s): s
        case .blob(let data): "<\(data.count) bytes>"
        }
    }
}

// MARK: SQLite

enum SQLiteRun {
    static func open(_ path: String, readOnly: Bool) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = readOnly
        config.busyMode = .timeout(5)
        config.label = "kelp.db"
        return try DatabaseQueue(path: path, configuration: config)
    }

    static func read(_ path: String, _ sql: String) throws -> DatabaseRows {
        try run {
            try open(path, readOnly: true).read { db in
                let statement = try db.makeStatement(sql: sql)
                guard statement.isReadonly else { throw DatabaseFailure.change }
                return try rows(statement)
            }
        }
    }

    static func trial(_ path: String, _ sql: String) throws -> DatabaseRows {
        try run {
            var result = DatabaseRows()
            try open(path, readOnly: false).inDatabase { db in
                try db.inTransaction {
                    let statement = try db.makeStatement(sql: SQLText.returning(sql) ?? sql)
                    result = try rows(statement)
                    result.changed = db.changesCount
                    return .rollback
                }
            }
            return result
        }
    }

    static func write(_ path: String, _ sql: String) throws -> DatabaseRows {
        try run {
            try open(path, readOnly: false).inDatabase { db in
                var result = try rows(try db.makeStatement(sql: sql))
                result.changed = db.changesCount
                return result
            }
        }
    }

    static func rows(_ statement: Statement) throws -> DatabaseRows {
        var result = DatabaseRows(columns: statement.columnNames)
        let cursor = try Row.fetchCursor(statement)
        while let row = try cursor.next() {
            result.total += 1
            if result.rows.count < DatabaseEngines.keep {
                result.rows.append(row.databaseValues.map(DatabaseEngines.text))
            }
            if result.total >= DatabaseEngines.countLimit { break }
        }
        return result
    }

    static func schema(_ path: String) throws -> DatabaseSchema {
        try run {
            try open(path, readOnly: true).read { db in
                let names = try String.fetchAll(
                    db,
                    sql:
                        "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
                        + " AND name NOT LIKE 'sqlite_%' ORDER BY name"
                )
                return DatabaseSchema(
                    tables: try names.map { name in
                        let keys = try db.foreignKeys(on: name)
                        let columns = try db.columns(in: name).map { column in
                            DatabaseSchema.Column(
                                name: column.name, type: column.type, nullable: !column.isNotNull,
                                primary: column.primaryKeyIndex > 0,
                                references: keys.first { $0.originColumns.contains(column.name) }.map {
                                    $0.destinationTable + "." + ($0.destinationColumns.first ?? "")
                                })
                        }
                        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(name.quotedDatabaseIdentifier)")
                        return DatabaseSchema.Table(
                            name: name, rows: count, columns: columns,
                            indexes: try db.indexes(on: name).map {
                                "\($0.name) (\($0.columns.joined(separator: ", ")))"
                            })
                    })
            }
        }
    }

    /// GRDB's error as the database said it.
    private static func run<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as DatabaseError {
            if error.resultCode == .SQLITE_READONLY { throw DatabaseFailure.change }
            throw DatabaseFailure.failed(error.message ?? error.description)
        }
    }
}

// MARK: Postgres

enum PostgresRun {
    /// Between a command's output and the next: what psql prints for `\echo`.
    static let marker = "--kelp-7f3e9c--"
    static let folders = [
        "/opt/homebrew/opt/libpq/bin", "/usr/local/opt/libpq/bin",
        "/Applications/Postgres.app/Contents/Versions/latest/bin",
        "/opt/homebrew/bin", "/usr/local/bin"
    ]

    static func read(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(
            c,
            [
                "BEGIN TRANSACTION READ ONLY", "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'",
                sql
            ],
            timeout: DatabaseEngines.readTimeout + 10)
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

    static func write(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(
            c, ["SET statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'", sql],
            timeout: DatabaseEngines.writeTimeout + 10)
        return section(out.last ?? "")
    }

    static func schema(_ c: DatabaseConnection) throws -> DatabaseSchema {
        let other = "NOT IN ('pg_catalog', 'information_schema', 'pg_toast')"
        let columns = """
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
        let counts = """
            SELECT CASE WHEN n.nspname = 'public' THEN c.relname ELSE n.nspname || '.' || c.relname END,
              c.reltuples::bigint
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname \(other)
            """
        let indexes = """
            SELECT CASE WHEN schemaname = 'public' THEN tablename ELSE schemaname || '.' || tablename END,
              indexname || ' ' || substring(indexdef from '\\((.*)\\)$')
            FROM pg_indexes WHERE schemaname \(other) ORDER BY indexname
            """
        let out = try run(
            c, ["BEGIN TRANSACTION READ ONLY", columns, counts, indexes], timeout: DatabaseEngines.readTimeout + 10)
        guard out.count >= 3 else { throw DatabaseFailure.failed("psql said nothing of the tables.") }
        return DatabaseSchemaBuilder.build(
            columns: section(out[out.count - 3]).rows, counts: section(out[out.count - 2]).rows,
            indexes: section(out[out.count - 1]).rows)
    }

    /// Each command's output after the first (BEGIN's), split at the markers psql echoes between them.
    static func run(_ c: DatabaseConnection, _ commands: [String], timeout: TimeInterval) throws -> [String] {
        let db = c.database
        var argv = [
            try DatabaseEngines.client("psql", also: folders), "-X", "-w", "--csv", "-v", "ON_ERROR_STOP=1",
            "-h", db.host ?? "localhost", "-p", String(db.port ?? 5432), "-d", db.database ?? "postgres"
        ]
        if let user = db.user { argv += ["-U", user] }
        for (index, command) in commands.enumerated() {
            if index > 0 { argv += ["-c", "\\echo " + marker] }
            argv += ["-c", command]
        }
        var env = ["PATH": "/usr/bin:/bin", "PGCONNECT_TIMEOUT": "5", "PGAPPNAME": "kelp", "LANG": "en_US.UTF-8"]
        env["PGPASSWORD"] = c.password
        let out = try Subprocess.run(argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeout, limit: 32 << 20)
        guard out.status == 0, !out.timedOut else {
            if out.timedOut { throw DatabaseFailure.failed("No answer from \(db.name) in \(Int(timeout)) s.") }
            throw failure(String(decoding: out.stderr, as: UTF8.self))
        }
        return String(decoding: out.stdout, as: UTF8.self).components(separatedBy: marker + "\n").dropFirst().map {
            $0
        }
    }

    /// psql's error: a change refused in a read-only transaction, or the server's own words.
    static func failure(_ stderr: String) -> DatabaseFailure {
        if stderr.contains("read-only transaction") { return .change }
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let said = lines.first { $0.hasPrefix("ERROR:") || $0.hasPrefix("psql: error:") || $0.hasPrefix("FATAL:") }
        let text = (said ?? lines.first ?? "psql failed")
            .replacingOccurrences(of: "psql: error: ", with: "").replacingOccurrences(of: "ERROR:  ", with: "")
        return .failed(text.trimmingCharacters(in: .whitespaces))
    }

    /// One command's output: rows as CSV (a header, then rows; NULL is an empty field without quotes), or the command's
    /// tag ("UPDATE 3"), whose number is what it changed.
    static func section(_ text: String) -> DatabaseRows {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.last == "" ? lines.dropLast() : lines[...]
        if body.count == 1, let tag = body.first,
            tag.range(of: #"^[A-Z]+( [A-Z]+)*( \d+)*$"#, options: .regularExpression) != nil
        {
            return DatabaseRows(changed: tag.split(separator: " ").last.flatMap { Int($0) })
        }
        var records = CSV.parse(text)
        guard !records.isEmpty else { return DatabaseRows() }
        let header = records.removeFirst().map { $0 ?? "" }
        return DatabaseRows(
            columns: header, rows: Array(records.prefix(DatabaseEngines.keep)), total: records.count)
    }
}

/// RFC 4180, as psql writes it: an unquoted empty field is NULL (nil), a quoted one an empty string.
enum CSV {
    static func parse(_ text: String) -> [[String?]] {
        var records: [[String?]] = [], record: [String?] = [], field = "", quoted = false, inQuotes = false
        var chars = text.makeIterator(), pending: Character?
        func endField() {
            record.append(field.isEmpty && !quoted ? nil : field)
            field = ""
            quoted = false
        }
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    let next = chars.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = next
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
                quoted = true
            case ",": endField()
            case "\n", "\r\n":
                endField()
                records.append(record)
                record = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || quoted || !record.isEmpty {
            endField()
            records.append(record)
        }
        return records
    }
}

// MARK: MySQL

/// Untested against a real server so far: written from mysql's documented batch output.
enum MySQLRun {
    static let marker = "kelp_7f3e9c"
    static let folders = [
        "/opt/homebrew/opt/mysql-client/bin", "/usr/local/opt/mysql-client/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/local/mysql/bin"
    ]

    static func read(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(
            c,
            [
                "SET SESSION max_execution_time = \(Int(DatabaseEngines.readTimeout * 1000))",
                "START TRANSACTION READ ONLY", sql
            ], timeout: DatabaseEngines.readTimeout + 10)
        return section(out.last ?? "")
    }

    static func trial(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(c, ["START TRANSACTION", sql, "SELECT ROW_COUNT()", "ROLLBACK"], timeout: 60)
        guard out.count >= 3 else { throw DatabaseFailure.failed("mysql said nothing of the change.") }
        var rows = section(out[out.count - 3])
        rows.changed = section(out[out.count - 2]).rows.first?.first.flatMap { $0.flatMap(Int.init) }
        return rows
    }

    static func write(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(c, [sql, "SELECT ROW_COUNT()"], timeout: DatabaseEngines.writeTimeout + 10)
        guard out.count >= 2 else { return DatabaseRows() }
        var rows = section(out[out.count - 2])
        rows.changed = section(out[out.count - 1]).rows.first?.first.flatMap { $0.flatMap(Int.init) }
        return rows
    }

    static func schema(_ c: DatabaseConnection) throws -> DatabaseSchema {
        let here = "table_schema = DATABASE()"
        let columns = """
            SELECT c.table_name, c.column_name, c.column_type, c.is_nullable, c.column_key = 'PRI',
              (SELECT CONCAT(k.referenced_table_name, '.', k.referenced_column_name)
               FROM information_schema.key_column_usage k
               WHERE k.table_schema = c.table_schema AND k.table_name = c.table_name AND k.column_name = c.column_name
               AND k.referenced_table_name IS NOT NULL LIMIT 1)
            FROM information_schema.columns c WHERE c.\(here) ORDER BY c.table_name, c.ordinal_position
            """
        let counts = "SELECT table_name, table_rows FROM information_schema.tables WHERE \(here)"
        let indexes = """
            SELECT table_name, CONCAT(index_name, ' (', GROUP_CONCAT(column_name ORDER BY seq_in_index), ')')
            FROM information_schema.statistics WHERE \(here) GROUP BY table_name, index_name
            """
        let out = try run(c, [columns, counts, indexes], timeout: DatabaseEngines.readTimeout + 10)
        guard out.count >= 3 else { throw DatabaseFailure.failed("mysql said nothing of the tables.") }
        return DatabaseSchemaBuilder.build(
            columns: section(out[out.count - 3]).rows, counts: section(out[out.count - 2]).rows,
            indexes: section(out[out.count - 1]).rows)
    }

    /// The statements as one script on stdin, in binary mode (no client commands such as `system`), a marker between
    /// them.
    static func run(_ c: DatabaseConnection, _ statements: [String], timeout: TimeInterval) throws -> [String] {
        let db = c.database
        var argv = [
            try DatabaseEngines.client("mysql", also: folders), "--batch", "--binary-mode",
            "-h", db.host ?? "127.0.0.1", "-P", String(db.port ?? 3306)
        ]
        if let user = db.user { argv += ["-u", user] }
        if let name = db.database { argv.append(name) }
        let script = statements.map { $0 + ";\nSELECT '\(marker)' AS \(marker);\n" }.joined()
        var env = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        env["MYSQL_PWD"] = c.password
        let out = try Subprocess.run(
            argv, cwd: NSHomeDirectory(), env: env, stdin: Data(script.utf8), timeLimit: timeout, limit: 32 << 20)
        guard out.status == 0, !out.timedOut else {
            if out.timedOut { throw DatabaseFailure.failed("No answer from \(db.name) in \(Int(timeout)) s.") }
            let said = String(decoding: out.stderr, as: UTF8.self)
            if said.contains("READ ONLY transaction") { throw DatabaseFailure.change }
            throw DatabaseFailure.failed(
                said.split(whereSeparator: \.isNewline).first.map(String.init) ?? "mysql failed")
        }
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

/// Tables out of three reads, the same for Postgres and MySQL: columns (table, column, type, nullable YES/NO, primary
/// t/1, references), row counts (table, count) and indexes (table, "name (columns)").
enum DatabaseSchemaBuilder {
    static func build(columns: [[String?]], counts: [[String?]], indexes: [[String?]]) -> DatabaseSchema {
        var names: [String] = [], byTable: [String: DatabaseSchema.Table] = [:]
        for row in columns where row.count >= 6 {
            guard let table = row[0], let name = row[1] else { continue }
            if byTable[table] == nil {
                names.append(table)
                byTable[table] = DatabaseSchema.Table(name: table)
            }
            byTable[table]?.columns.append(
                DatabaseSchema.Column(
                    name: name, type: row[2] ?? "", nullable: row[3] == "YES",
                    primary: ["t", "1", "true"].contains(row[4]),
                    references: row[5]))
        }
        for row in counts where row.count >= 2 {
            guard let table = row[0], let count = row[1].flatMap(Int.init), count >= 0 else { continue }
            byTable[table]?.rows = count
        }
        for row in indexes where row.count >= 2 {
            guard let table = row[0], let index = row[1] else { continue }
            byTable[table]?.indexes.append(index)
        }
        return DatabaseSchema(tables: names.compactMap { byTable[$0] })
    }
}
