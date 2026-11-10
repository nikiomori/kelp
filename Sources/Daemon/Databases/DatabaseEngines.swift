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
    /// Where Kelp has it from: a project's files, added by hand to the project, or All My Projects (the user's own,
    /// reached from this Mac whatever project it's used in).
    var origin: Origin = .found

    enum Origin: Sendable { case found, project, library }
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
    /// What the kept rows' cells weigh; past `DatabaseEngines.outputLimit` no more are kept and the answer is refused
    /// (`DatabaseEngines.whole`), never sent as fewer rows. Not part of what it says (==).
    var bytes = 0

    /// One more row as it comes: kept up to `DatabaseEngines.keep` and `outputLimit`, counted always.
    mutating func add(columns: [String], _ row: [String?]) {
        if total == 0 { self.columns = columns }
        add(row)
    }

    mutating func add(_ row: [String?]) {
        total += 1
        guard rows.count < DatabaseEngines.keep, bytes <= DatabaseEngines.outputLimit else { return }
        bytes += row.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        if bytes <= DatabaseEngines.outputLimit { rows.append(row) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.columns == rhs.columns && lhs.rows == rhs.rows && lhs.total == rhs.total && lhs.changed == rhs.changed
    }
}

/// Runs statements on a database: SQLite in kelpd (GRDB), Postgres and MySQL over their own protocols
/// (`DatabaseWire`) at an address kelpd reaches, or through their clients inside the compose container that runs them
/// when there's no such address (`docker exec`). A read runs in a read-only transaction (a read-only file for SQLite),
/// so the database itself refuses a change; a trial runs a change and rolls it back; a write runs it on its own. One
/// statement each (`SQLText.single`). What blocks (GRDB, a client run) goes to `off`, never the cooperative pool.
enum DatabaseEngines {
    /// Rows kept of a result; more are counted up to `countLimit`.
    static let keep = QueryResult.kept, countLimit = QueryResult.counted
    /// A read's time limit, and a change's.
    static let readTimeout = DatabaseTimes.read, writeTimeout = DatabaseTimes.write
    /// What Kelp reads of a client's output: an answer past it is refused whole, never read as fewer rows.
    static let outputLimit = 32 << 20

    static func whole(_ out: Subprocess.Output, _ name: String) throws {
        guard out.truncated else { return }
        throw tooBig(name)
    }

    /// A change that would change more or fewer rows than the user allowed (the table changed while it was asked).
    static func notAsAllowed(_ changed: Int?, _ allowed: Int) -> DatabaseFailure {
        let rows = { (count: Int) in "\(count) \(count == 1 ? "row" : "rows")" }
        let now = changed.map(rows) ?? "an unknown number of rows"
        return .failed(
            "It would change \(now) now, not the \(rows(allowed)) the user allowed: nothing changed. "
                + "Run it again to ask again.")
    }

    /// Rows read in kelpd (SQLite, over the wire): refused whole past `outputLimit`, as a client's output is.
    static func whole(_ rows: DatabaseRows, _ name: String) throws -> DatabaseRows {
        guard rows.bytes > outputLimit else { return rows }
        throw tooBig(name)
    }

    private static func tooBig(_ name: String) -> DatabaseFailure {
        .failed(
            "\(name)'s answer is over \(outputLimit >> 20) MB, more than Kelp reads: ask for fewer rows or columns.")
    }

    /// `timeout`: seconds the server may take (Postgres stops it there).
    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval = readTimeout, off: Slots)
        async throws -> DatabaseRows
    {
        try whole(
            try await explained(c) {
                try await runner(c, off: off).read(sql, timeout: timeout)
            }, c.database.name)
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
        return try whole(try await runner(c, off: off).trial(sql), c.database.name)
    }

    /// `allowed`: the rows the user allowed it to change (its trial's), committed only if it changes as many where the
    /// runner `holdsAllowed`; elsewhere (Appwrite) it runs as asked, so a table changed while it was asked can change a
    /// different number.
    static func write(_ c: DatabaseConnection, _ sql: String, allowed: Int? = nil, off: Slots) async throws
        -> DatabaseRows
    {
        try whole(try await runner(c, off: off).write(sql, allowed: allowed), c.database.name)
    }

    /// The user's edits, all or none, in one transaction: the rows they changed. Through a container's client too: a
    /// failure stops it before COMMIT, and the session it ends rolls back.
    static func apply(_ c: DatabaseConnection, _ statements: [String], off: Slots) async throws -> Int {
        try await runner(c, off: off).apply(statements)
    }

    static func schema(_ c: DatabaseConnection, table: String?, off: Slots) async throws -> DatabaseSchema {
        let schema = try await explained(c) { try await runner(c, off: off).schema() }
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
        let docker = try client("docker", also: Databases.dockerFolders)
        guard let id = Databases.container(service, docker: docker) else {
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
        case .int64(let int): String(int)
        case .double(let double): String(double)
        case .string(let text): text
        case .blob(let data): "<\(data.count) bytes>"
        }
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
        while let char = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    let next = chars.next()
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        pending = next
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"":
                inQuotes = true
                quoted = true
            case ",": endField()
            case "\n", "\r\n":
                endField()
                records.append(record)
                record = []
            default: field.append(char)
            }
        }
        if !field.isEmpty || quoted || !record.isEmpty {
            endField()
            records.append(record)
        }
        return records
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
