import Core
import Foundation
import GRDB

/// A database and the password that opens it, as kelpd holds them: never sent to a client.
struct DatabaseConnection: Sendable {
    var database: DatabaseInfo
    var password: String?
    /// The compose service it runs in (its file, absolute): where its client runs when this Mac has none, or the
    /// service publishes no port.
    var container: ComposeService?
    /// Kelp's keychain account for its password ("db:<project>/<name>"): where one read from `passwordIn` goes.
    var account: String?
}

struct ComposeService: Sendable, Equatable {
    var file: String, name: String, port: Int
}

/// What a statement gave: its columns and rows (nil for NULL), `total` counted past what's kept up to `countLimit`.
struct DatabaseRows: Equatable, Sendable {
    var columns: [String] = []
    var rows: [[String?]] = []
    var total = 0
    var changed: Int?

    /// One more row as it comes: kept up to `DatabaseEngines.keep`, counted always.
    mutating func add(columns: [String], _ row: [String?]) {
        if total == 0 { self.columns = columns }
        total += 1
        if rows.count < DatabaseEngines.keep { rows.append(row) }
    }
}

/// Runs statements on a database: SQLite in kelpd (GRDB), Postgres and MySQL over their own protocols
/// (`DatabaseWire`) at an address kelpd reaches, or through their clients inside the compose container that runs them
/// when there's no such address (`docker exec`). A read runs in a read-only transaction (a read-only file for SQLite),
/// so the database itself refuses a change; a trial runs a change and rolls it back; a write runs it on its own. One
/// statement each (`SQLText.single`). What blocks (GRDB, a client run) goes to `off`, never the cooperative pool.
enum DatabaseEngines {
    /// Rows kept of a result; more are counted up to `countLimit`.
    static let keep = 1000, countLimit = 100_000
    /// A read's time limit, and a change's.
    static let readTimeout: TimeInterval = 15, writeTimeout: TimeInterval = 300
    /// What Kelp reads of a client's output: an answer past it is refused whole, never read as fewer rows.
    static let outputLimit = 32 << 20

    static func whole(_ out: Subprocess.Output, _ name: String) throws {
        guard out.truncated else { return }
        throw DatabaseFailure.failed(
            "\(name)'s answer is over \(outputLimit >> 20) MB, more than Kelp reads: ask for fewer rows or columns.")
    }

    /// `timeout`: seconds the server may take (Postgres stops it there).
    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval = readTimeout, off: Slots)
        async throws -> DatabaseRows
    {
        try await explained(c) {
            switch (c.database.engine, c.database.host) {
            case (.sqlite, _): try await off.run { try SQLiteRun.read(path(c), sql, timeout: timeout) }
            case (.duckdb, _): try await off.run { try DuckDBRun.read(path(c), sql, timeout: timeout) }
            case (.appwrite, _): try await AppwriteWire.read(c, sql)
            case (.postgres, .some): try await PostgresWire.read(c, sql, timeout: timeout)
            case (.mysql, .some): try await MySQLWire.read(c, sql, timeout: timeout)
            case (.postgres, nil): try await off.run { try PostgresRun.read(c, sql, timeout: timeout) }
            case (.mysql, nil): try await off.run { try MySQLRun.read(c, sql, timeout: timeout) }
            }
        }
    }

    /// A server that isn't up, said with how to start it when a compose file runs it.
    static func explained<T>(_ c: DatabaseConnection, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch DatabaseFailure.failed(let text)
            where text.contains("Connection refused") || text.contains("Can't connect")
        {
            let start =
                c.database.source.map { source in
                    DatabaseFind.composeFiles.contains(source)
                        ? " Is it running? docker compose up -d starts what \(source) runs." : ""
                } ?? ""
            let place = c.database.host == nil ? c.container.map { "its compose service \($0.name)" } : nil
            throw DatabaseFailure.failed(
                "\(c.database.name) doesn't answer at \(place ?? c.database.address).\(start)")
        }
    }

    /// The change made and rolled back: what it touched, and the rows it would leave when it can say (RETURNING).
    static func trial(_ c: DatabaseConnection, _ sql: String, off: Slots) async throws -> DatabaseRows {
        guard SQLText.mayTry(sql, c.database.engine) else {
            throw DatabaseFailure.failed("\(SQLText.verb(sql)) can't be tried in a transaction there")
        }
        return switch (c.database.engine, c.database.host) {
        case (.sqlite, _): try await off.run { try SQLiteRun.trial(path(c), sql) }
        case (.duckdb, _): try await off.run { try DuckDBRun.trial(path(c), sql) }
        case (.appwrite, _): try await AppwriteWire.trial(c, sql)
        case (.postgres, .some): try await PostgresWire.trial(c, sql)
        case (.mysql, .some): try await MySQLWire.trial(c, sql)
        case (.postgres, nil): try await off.run { try PostgresRun.trial(c, sql) }
        case (.mysql, nil): try await off.run { try MySQLRun.trial(c, sql) }
        }
    }

    static func write(_ c: DatabaseConnection, _ sql: String, off: Slots) async throws -> DatabaseRows {
        switch (c.database.engine, c.database.host) {
        case (.sqlite, _): try await off.run { try SQLiteRun.write(path(c), sql) }
        case (.duckdb, _): try await off.run { try DuckDBRun.write(path(c), sql) }
        case (.appwrite, _): try await AppwriteWire.write(c, sql)
        case (.postgres, .some): try await PostgresWire.write(c, sql)
        case (.mysql, .some): try await MySQLWire.write(c, sql)
        case (.postgres, nil): try await off.run { try PostgresRun.write(c, sql) }
        case (.mysql, nil): try await off.run { try MySQLRun.write(c, sql) }
        }
    }

    /// The user's edits, all or none, in one transaction: the rows they changed. Through a container's client too: a
    /// failure stops it before COMMIT, and the session it ends rolls back.
    static func apply(_ c: DatabaseConnection, _ statements: [String], off: Slots) async throws -> Int {
        switch (c.database.engine, c.database.host) {
        case (.sqlite, _): try await off.run { try SQLiteRun.apply(path(c), statements) }
        case (.duckdb, _): try await off.run { try DuckDBRun.apply(path(c), statements) }
        case (.appwrite, _): try await AppwriteWire.apply(c, statements)
        case (.postgres, .some): try await PostgresWire.apply(c, statements)
        case (.mysql, .some): try await MySQLWire.apply(c, statements)
        case (.postgres, nil): try await off.run { try PostgresRun.apply(c, statements) }
        case (.mysql, nil): try await off.run { try MySQLRun.apply(c, statements) }
        }
    }

    static func schema(_ c: DatabaseConnection, table: String?, off: Slots) async throws -> DatabaseSchema {
        let schema: DatabaseSchema = try await explained(c) {
            switch (c.database.engine, c.database.host) {
            case (.sqlite, _): try await off.run { try SQLiteRun.schema(path(c)) }
            case (.duckdb, _): try await off.run { try DuckDBRun.schema(path(c)) }
            case (.appwrite, _): try await AppwriteWire.schema(c)
            case (.postgres, .some): try await PostgresWire.schema(c)
            case (.mysql, .some): try await MySQLWire.schema(c)
            case (.postgres, nil): try await off.run { try PostgresRun.schema(c) }
            case (.mysql, nil): try await off.run { try MySQLRun.schema(c) }
            }
        }
        guard let table else { return schema }
        let one = schema.tables.filter { $0.name.caseInsensitiveCompare(table) == .orderedSame }
        guard !one.isEmpty else {
            throw DatabaseFailure.failed("No table \(table) in \(c.database.name). Its tables: kelp db schema")
        }
        return DatabaseSchema(tables: one)
    }

    static func path(_ c: DatabaseConnection) throws -> String {
        guard let path = c.database.path, FileManager.default.fileExists(atPath: path) else {
            throw DatabaseFailure.failed("\(c.database.name)'s file isn't there: \(c.database.path ?? "no path").")
        }
        return path
    }

    /// How to run the client inside the container compose runs the database in (`docker exec`, its port there), with
    /// `secret` (the password's variable) passed from the environment, never on the command line. A database with an
    /// address is spoken to directly (`DatabaseWire`).
    static func invocation(_ c: DatabaseConnection, _ name: String, secret: String) throws -> (
        argv: [String], host: String, port: Int
    ) {
        guard let service = c.container else {
            throw DatabaseFailure.failed("\(c.database.name) has no address to reach it at.")
        }
        let docker = try client(
            "docker", also: ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin"])
        let id = Subprocess.printed(
            [docker, "compose", "-f", service.file, "ps", "-q", service.name], path: "/usr/local/bin:/usr/bin:/bin",
            timeout: 15)?.split(whereSeparator: \.isNewline).first.map(String.init)
        guard let id, !id.isEmpty else {
            throw DatabaseFailure.failed(
                "\(service.name) isn't running: docker compose up -d \(service.name) starts it.")
        }
        return ([docker, "exec", "-i", "-e", secret, id, name], "127.0.0.1", service.port)
    }

    /// What every client run gets: a short PATH, a UTF-8 locale, and the home folder (docker reads its settings there).
    static func environment(_ more: [String: String?]) -> [String: String] {
        var env = ["PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()]
        for (key, value) in more { env[key] = value }
        return env
    }

    /// The client program, from the login PATH or where it's usually kept (libpq is keg-only in Homebrew).
    static func client(_ name: String, also: [String]) throws -> String {
        do { return try LoginPath.resolve(name) } catch {}   // not on the PATH: where it's usually kept
        if let found = also.map({ $0 + "/" + name }).first(where: FileManager.default.isExecutableFile(atPath:)) {
            return found
        }
        let hint = name == "duckdb" ? ": brew install duckdb" : ""
        throw DatabaseFailure.failed("\(name) isn't installed, and Kelp reaches this database through it\(hint).")
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

    /// Stopped at `timeout` (`interrupt`, from another thread): a runaway join doesn't keep its slot.
    static func read(_ path: String, _ sql: String, timeout: TimeInterval) throws -> DatabaseRows {
        try run {
            let queue = try open(path, readOnly: true)
            let stop = DispatchWorkItem { queue.interrupt() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
            defer { stop.cancel() }
            do {
                return try queue.read { db in
                    let statement = try db.makeStatement(sql: sql)
                    guard statement.isReadonly else { throw DatabaseFailure.change }
                    return try rows(statement)
                }
            } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
                throw DatabaseFailure.failed("It took more than \(Int(timeout)) s.")
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

    static func apply(_ path: String, _ statements: [String]) throws -> Int {
        try run {
            var changed = 0
            try open(path, readOnly: false).inTransaction { db in
                for sql in statements {
                    try db.execute(sql: sql)
                    changed += db.changesCount
                }
                return .commit
            }
            return changed
        }
    }

    /// A consistent copy of the file, written or not while it's read (SQLite's own backup).
    static func copy(_ path: String, to target: String) throws {
        try run {
            let source = try open(path, readOnly: true)
            try source.backup(to: try DatabaseQueue(path: target))
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
                let views = Set(
                    try String.fetchAll(
                        db, sql: "SELECT name FROM sqlite_master WHERE type = 'view' AND name NOT LIKE 'sqlite_%'"))
                let names = try String.fetchAll(
                    db,
                    sql:
                        "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
                        + " AND name NOT LIKE 'sqlite_%' ORDER BY name"
                )
                return DatabaseSchema(
                    tables: try names.map { name in
                        let view = views.contains(name)   // a view has no keys or indexes of its own
                        let keys = view ? [] : try db.foreignKeys(on: name)
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
                            indexes: view
                                ? []
                                : try db.indexes(on: name).map {
                                    "\($0.name) (\($0.columns.joined(separator: ", ")))"
                                }, kind: view ? "view" : nil)
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

    static func write(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(
            c, ["SET statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'", sql],
            timeout: DatabaseEngines.writeTimeout + 10)
        return section(out.last ?? "")
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

    /// Each command's output after the first (BEGIN's), split at the markers psql echoes between them.
    static func run(_ c: DatabaseConnection, _ commands: [String], timeout: TimeInterval) throws -> [String] {
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
        let env = DatabaseEngines.environment([
            // UTC as over the wire (`PostgresText`): a row found by its values compares the same text
            "PGCONNECT_TIMEOUT": "5", "PGAPPNAME": "kelp", "PGPASSWORD": c.password, "PGTZ": "UTC"
        ])
        let out = try Subprocess.run(
            argv, cwd: NSHomeDirectory(), env: env, timeLimit: timeout, limit: DatabaseEngines.outputLimit)
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

/// RFC 4180: an unquoted empty field is nil, a quoted one an empty string (psql writes both unquoted: `PostgresRun.null`).
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

/// mysql inside a compose container (`docker exec`): its batch output.
enum MySQLRun {
    static let marker = "kelp_7f3e9c"

    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval) throws -> DatabaseRows {
        // No server-side limit: MySQL names it max_execution_time, MariaDB max_statement_time, and each refuses the
        // other's. The client is stopped at `timeout` instead.
        let out = try run(c, ["START TRANSACTION READ ONLY", sql], timeout: timeout)
        return section(out.last ?? "")
    }

    static func trial(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(c, ["START TRANSACTION", counted(sql), "ROLLBACK"], timeout: 60)
        guard out.count >= 2 else { throw DatabaseFailure.failed("mysql said nothing of the change.") }
        return withCount(out[out.count - 2])
    }

    static func write(_ c: DatabaseConnection, _ sql: String) throws -> DatabaseRows {
        let out = try run(c, [counted(sql)], timeout: DatabaseEngines.writeTimeout + 10)
        return out.last.map(withCount) ?? DatabaseRows()
    }

    /// One script: mysql stops at the first error (no --force), so COMMIT never comes and its session rolls back.
    static func apply(_ c: DatabaseConnection, _ statements: [String]) throws -> Int {
        let out = try run(
            c, ["START TRANSACTION"] + statements.map(counted) + ["COMMIT"], timeout: DatabaseEngines.writeTimeout + 10)
        return out.dropFirst().dropLast().map { withCount($0).changed ?? 0 }.reduce(0, +)
    }

    /// The statement and, right after it (anything between would reset it), the rows it changed.
    static let changedColumn = "kelp_changed"
    static func counted(_ sql: String) -> String { sql + ";\nSELECT ROW_COUNT() AS " + changedColumn }

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
            guard let table = row[0] else { continue }
            if let count = row[1].flatMap(Int.init), count >= 0 { byTable[table]?.rows = count }
            if row.count >= 5 {   // kind, size and comment where the engine's query gives them
                byTable[table]?.kind = row[2] ?? nil
                byTable[table]?.bytes = row[3].flatMap { Int($0) }
                byTable[table]?.comment = row[4] ?? nil
            }
        }
        for row in indexes where row.count >= 2 {
            guard let table = row[0], let index = row[1] else { continue }
            byTable[table]?.indexes.append(index)
        }
        return DatabaseSchema(tables: names.compactMap { byTable[$0] })
    }
}
