import Core
import Foundation
import GRDB

/// A database and the password that opens it, as kelpd holds them. It is never sent to a client.
struct DatabaseConnection: Sendable {
    var database: DatabaseInfo
    var password: String?
    /// The compose service the database runs in, with the compose file's absolute path. The database's client runs
    /// there when this Mac has no client, or when the service publishes no port.
    var container: ComposeService?
    /// Kelp's keychain account for the database's password ("db:<project>/<name>"). A password read from
    /// `passwordIn` is saved there.
    var account: String?
    /// Where Kelp got the database from: a project's files, the project's databases added by hand, or All my projects
    /// (the user's own databases, reached from this Mac whichever project uses them).
    var origin: Origin = .found
    /// The server's own name when `database.host` is a forwarded port's (`Databases.reach`): TLS checks it.
    var serverName: String?

    enum Origin: Sendable { case found, project, library }
}

struct ComposeService: Sendable, Equatable {
    var file: String, name: String, port: Int
}

/// What a statement returned: its columns and rows (nil for NULL). `total` keeps counting rows past the ones kept, up
/// to `countLimit`.
struct DatabaseRows: Equatable, Sendable {
    var columns: [String] = []
    var rows: [[String?]] = []
    var total = 0
    var changed: Int?
    /// The size in bytes of the kept rows' cells. Past `DatabaseEngines.outputLimit` no more rows are kept and the
    /// answer is refused (`DatabaseEngines.whole`), never sent as fewer rows. `==` ignores this field.
    var bytes = 0
    /// Whether some value isn't its own text (a SQLite blob, shown as its size). Then the rows can't be written back
    /// as they are.
    var opaque = false

    /// Adds one more row as it comes. The row is kept up to `DatabaseEngines.keep` rows and `outputLimit` bytes, and
    /// it is always counted.
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

/// Runs statements on a database. SQLite runs inside kelpd (GRDB). Postgres and MySQL are spoken to over their own
/// protocols (`DatabaseWire`) at an address kelpd can reach, or, when there is no such address, through their clients
/// inside the compose container that runs them (`docker exec`).
/// A read runs in a read-only transaction (a read-only file for SQLite), so the database itself refuses a change. A
/// trial runs a change and rolls it back, and a write runs it for real. Each of these runs one statement
/// (`SQLText.single`). Blocking work (GRDB, a client run) goes to the `off` slots, never to the cooperative pool.
enum DatabaseEngines {
    /// The number of rows kept of a result. Rows past that are counted, up to `countLimit`.
    static let keep = QueryResult.kept, countLimit = QueryResult.counted
    /// The time limits for a read and for a change.
    static let readTimeout = DatabaseTimes.read, writeTimeout = DatabaseTimes.write
    /// The most bytes Kelp reads of a client's output. An answer past it is refused whole, never read as fewer rows.
    static let outputLimit = 32 << 20

    static func whole(_ out: Subprocess.Output, _ name: String) throws {
        guard out.truncated else { return }
        throw tooBig(name)
    }

    /// The failure for a change that would change more or fewer rows than the user allowed, because the table changed
    /// while the user was asked.
    static func notAsAllowed(_ changed: Int?, _ allowed: Int) -> DatabaseFailure {
        let rows = { (count: Int) in "\(count) \(count == 1 ? "row" : "rows")" }
        let now = changed.map(rows) ?? "an unknown number of rows"
        return .failed(
            "It would change \(now) now, not the \(rows(allowed)) the user allowed: nothing changed. "
                + "Run it again to ask again.")
    }

    /// Refuses rows read in kelpd (SQLite, over the wire) whole when they pass `outputLimit`, as a client's output is.
    static func whole(_ rows: DatabaseRows, _ name: String) throws -> DatabaseRows {
        guard rows.bytes > outputLimit else { return rows }
        throw tooBig(name)
    }

    /// Reads an HTTP answer (Appwrite's) up to `limit` bytes, and refuses a longer one whole, as a client's output is.
    static func answer(_ request: URLRequest, from name: String, limit: Int = DatabaseEngines.outputLimit) async throws
        -> (Data, URLResponse)
    {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard response.expectedContentLength <= Int64(limit) else { throw tooBig(name) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else { throw tooBig(name) }
        }
        return (data, response)
    }

    private static func tooBig(_ name: String) -> DatabaseFailure {
        .failed(
            "\(name)'s answer is over \(outputLimit >> 20) MB, more than Kelp reads: ask for fewer rows or columns.")
    }

    /// Runs a read. `timeout` is the number of seconds the server may take (Postgres stops the read there).
    static func read(
        _ databaseConnection: DatabaseConnection, _ sql: String, timeout: TimeInterval = readTimeout, off: Slots
    )
        async throws -> DatabaseRows
    {
        try whole(
            try await explained(databaseConnection) {
                try await runner(databaseConnection, off: off).read(sql, timeout: timeout)
            }, databaseConnection.database.name)
    }

    /// Reports a server that isn't up, with how to start it when a compose file runs it.
    static func explained<T>(_ databaseConnection: DatabaseConnection, _ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch DatabaseFailure.failed(let text)
            where text.contains("Connection refused") || text.contains("Can't connect")
        {
            let start =
                databaseConnection.database.source.map { source in
                    DatabaseFind.composeFiles.contains(source)
                        ? " Is it running? docker compose up -d starts what \(source) runs." : ""
                } ?? ""
            let place =
                databaseConnection.database.host == nil
                ? databaseConnection.container.map { "its compose service \($0.name)" } : nil
            throw DatabaseFailure.failed(
                "\(databaseConnection.database.name) doesn't answer at \(place ?? databaseConnection.database.address).\(start)"
            )
        }
    }

    /// Makes the change and rolls it back. Returns how many rows it touched, and the rows it would leave when the
    /// engine can say so (RETURNING).
    static func trial(_ databaseConnection: DatabaseConnection, _ sql: String, off: Slots) async throws -> DatabaseRows
    {
        guard SQLText.mayTry(sql, databaseConnection.database.engine) else {
            throw DatabaseFailure.failed("\(SQLText.verb(sql)) can't be tried in a transaction there")
        }
        return try whole(try await runner(databaseConnection, off: off).trial(sql), databaseConnection.database.name)
    }

    /// Makes a change. `allowed` is the number of rows the user allowed it to change (the trial's count). Where the
    /// runner `holdsAllowed`, the change is committed only if it changes that many. Elsewhere (Appwrite) it runs as
    /// asked, so a table that changed while the user was asked can have a different number of rows changed.
    static func write(_ databaseConnection: DatabaseConnection, _ sql: String, allowed: Int? = nil, off: Slots)
        async throws
        -> DatabaseRows
    {
        try whole(
            try await runner(databaseConnection, off: off).write(sql, allowed: allowed),
            databaseConnection.database.name)
    }

    /// Runs the user's edits in one transaction, so all of them are kept or none, and returns how many rows they
    /// changed. That holds through a container's client too, because a failure stops the client before COMMIT and
    /// the session it ends rolls back.
    static func apply(_ databaseConnection: DatabaseConnection, _ statements: [String], off: Slots) async throws -> Int
    {
        try await runner(databaseConnection, off: off).apply(statements)
    }

    /// Runs several statements in one transaction, kept when `keep` approves the rows each changed
    /// (`DatabaseRunner.batch`).
    static func batch(
        _ databaseConnection: DatabaseConnection, _ statements: [String], keep: @escaping @Sendable ([Int?]) -> Bool,
        off: Slots
    ) async throws -> [Int?] {
        try await explained(databaseConnection) {
            try await runner(databaseConnection, off: off).batch(statements, keep: keep)
        }
    }

    static func schema(_ databaseConnection: DatabaseConnection, table: String?, off: Slots) async throws
        -> DatabaseSchema
    {
        let schema = try await explained(databaseConnection) { try await runner(databaseConnection, off: off).schema() }
        guard let table else { return schema }
        let one = schema.tables.filter { $0.name.caseInsensitiveCompare(table) == .orderedSame }
        guard !one.isEmpty else {
            throw DatabaseFailure.failed(
                "No table \(table) in \(databaseConnection.database.name). Its tables: kelp db schema")
        }
        return DatabaseSchema(tables: one)
    }

    static func path(_ databaseConnection: DatabaseConnection) throws -> String {
        guard let path = databaseConnection.database.path, FileManager.default.fileExists(atPath: path) else {
            throw DatabaseFailure.failed(
                "\(databaseConnection.database.name)'s file isn't there: \(databaseConnection.database.path ?? "no path")."
            )
        }
        return path
    }

    /// Returns how to run the client inside the container that compose runs the database in (`docker exec`, and the
    /// port inside the container). `pass` names the variables (the password's among them) that are passed from the
    /// environment, never on the command line. A database with an address is spoken to directly (`DatabaseWire`).
    static func invocation(_ databaseConnection: DatabaseConnection, _ name: String, pass: [String]) throws -> (
        argv: [String], host: String, port: Int
    ) {
        guard let service = databaseConnection.container else {
            throw DatabaseFailure.failed("\(databaseConnection.database.name) has no address to reach it at.")
        }
        let docker = try client("docker", also: Databases.dockerFolders)
        guard let id = Databases.container(service, docker: docker) else {
            throw DatabaseFailure.failed(
                "\(service.name) isn't running: docker compose up -d \(service.name) starts it.")
        }
        return ([docker, "exec", "-i"] + pass.flatMap { ["-e", $0] } + [id, name], "127.0.0.1", service.port)
    }

    /// What every client run gets: a short PATH, a UTF-8 locale, and the home folder (docker reads its settings there).
    static func environment(_ more: [String: String?]) -> [String: String] {
        var env = ["PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()]
        for (key, value) in more { env[key] = value }
        return env
    }

    /// Finds the client program on the login PATH or where it's usually kept (libpq is keg-only in Homebrew).
    static func client(_ name: String, also: [String]) throws -> String {
        do { return try LoginPath.resolve(name) } catch {}   // not on the PATH, so look where it's usually kept
        if let found = also.map({ $0 + "/" + name }).first(where: FileManager.default.isExecutableFile(atPath:)) {
            return found
        }
        let hint = name == "duckdb" ? ": brew install duckdb" : ""
        throw DatabaseFailure.failed("\(name) isn't installed, and Kelp reaches this database through it\(hint).")
    }

    /// Returns a SQLite value as text: numbers as SQLite gives them, and a blob as its size.
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

/// Parses RFC 4180 CSV. An unquoted empty field is nil and a quoted one is an empty string (psql writes both unquoted,
/// which is why `PostgresRun.null` exists).
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

/// Builds the tables from three reads that have the same shape for Postgres, MySQL and DuckDB: columns (table, column,
/// type, nullable YES/NO, primary t/1, references), row counts (table, count) and indexes (table, "name (columns)").
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
            if row.count >= 5 {   // some engines' queries also give the kind, size and comment
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
