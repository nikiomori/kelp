import Foundation

// Value types for a project's databases. kelpd finds, runs and keeps them, and the app shows them (the `db.*` methods
// are in DatabaseMethods).

/// Builds and reads the address of a database tab, `db:<workspace>/<name>`. The tab can show one run (`?run=`), one
/// table (`?table=`), or how a branch's copy differs from the database it copies (`?compare=<original>`). The name and
/// the table are percent-encoded, because an imported name may hold a "?" or "/". This is the only place that builds
/// the address (for the tab, the agent's row and `kelp db`) and the only place that reads it (`parts`). The daemon
/// decides whether an agent may open a tab by the workspace and database the tab will show, so both sides must read an
/// address the same way.
public enum DatabaseTabURI {
    /// Returns the workspace and database that `uri` names, and the text after its "?". Returns nil when `uri` isn't a
    /// database tab's address.
    public static func parts(_ uri: String) -> (worktree: String, name: String, query: String?)? {
        guard let colon = uri.firstIndex(of: ":"), uri[..<colon].lowercased() == "db" else { return nil }
        let body = uri[uri.index(after: colon)...].split(separator: "?", maxSplits: 1)
        let parts = body.first?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1].removingPercentEncoding ?? parts[1], body.count > 1 ? String(body[1]) : nil)
    }

    public static func uri(
        worktree: String, name: String, run: String? = nil, table: String? = nil, compare: String? = nil
    ) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?/")
        let name = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let table = table.map { "?table=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) }
        let compare = compare.map { "?compare=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0) }
        return "db:\(worktree)/\(name)" + (run.map { "?run=" + $0 } ?? table ?? compare ?? "")
    }
}

/// A project's database, either found in the project's files (compose, .env, database.yml, a SQLite file) or added by
/// hand.
public struct DatabaseInfo: Codable, Sendable, Equatable, Identifiable {
    public enum Engine: String, Codable, Sendable, CaseIterable {
        /// Appwrite is a database reached over its REST API. The host is the endpoint, the user is the Appwrite
        /// project's ID, and the password is an API key. Kelp reads and changes its rows through a narrow SQL that it
        /// translates.
        case sqlite, postgres, mysql, duckdb, appwrite

        /// A file on disk rather than a server.
        public var isFile: Bool { self == .sqlite || self == .duckdb }

        /// The port the engine's server uses unless told otherwise. nil for a file, and for Appwrite, whose endpoint is
        /// a URL.
        public var defaultPort: Int? {
            switch self {
            case .postgres: 5432
            case .mysql: 3306
            case .sqlite, .duckdb, .appwrite: nil
            }
        }

        /// The engine's name wherever Kelp shows it, as in "Postgres · compose.yaml" or a check's "SQLite".
        public var displayName: String {
            switch self {
            case .sqlite: "SQLite"
            case .postgres: "Postgres"
            case .mysql: "MySQL"
            case .duckdb: "DuckDB"
            case .appwrite: "Appwrite"
            }
        }

        /// The character the engine's SQL quotes a name in: "orders", or `orders` in MySQL.
        public var identifierQuote: Character { self == .mysql ? "`" : "\"" }

        /// The engine a container image runs, judged by the image's whole name and not its registry or owner. Examples
        /// are postgres:16, bitnami/postgresql, timescale/timescaledb-ha, mariadb and percona-server. nil for other
        /// images, such as postgrest or postgres-exporter, which only have a database's name in theirs.
        public init?(image: String) {
            let last = image.lowercased().split(separator: "/").last ?? ""
            let name = String(last.split(whereSeparator: { $0 == ":" || $0 == "@" }).first ?? "")
            if ["postgres", "postgresql", "postgis", "timescaledb", "timescaledb-ha", "pgvector"].contains(name) {
                self = .postgres
            } else if ["mysql", "mysql-server", "mariadb", "percona", "percona-server"].contains(name) {
                self = .mysql
            } else {
                return nil
            }
        }
    }

    /// Whether a host is this Mac (or its Docker), meaning a loopback address or this Mac's own name. A `.local` name
    /// doesn't count, because whoever answers for it on the network could be another machine. A name without a dot
    /// doesn't count either, because it may be a compose service or a host in a search domain. A name that only starts
    /// with "127." ("127.evil.example") is a name, not the loopback address.
    public static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "::1", "0.0.0.0", "host.docker.internal", thisMac].contains(host)
            || isLoopbackIPv4(host) || host.hasSuffix(".localhost")
    }

    /// An address in 127.0.0.0/8 written as four numbers.
    private static func isLoopbackIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127"
            && parts.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) } && UInt8($0) != nil }
    }

    /// Read with gethostname rather than ProcessInfo.hostName, because gethostname does no DNS lookup.
    private static let thisMac: String = {
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, name.count) == 0 else { return "localhost" }
        return String(cBuffer: name).lowercased()
    }()

    /// A single key for where the database lives. It is the file for a file database. For a server it is the host (with
    /// this Mac under any of its names counting as one), the port, the database and the SSH host. Two entries with the
    /// same place are one database, so what the user set for one holds for the other.
    public var place: String {
        if engine.isFile { return [engine.rawValue, path ?? ""].joined(separator: "\u{1F}") }
        let at = host.map { Self.isLocal($0) ? "localhost" : $0.lowercased() } ?? ""
        return [engine.rawValue, at, port.map(String.init) ?? "", database ?? "", ssh ?? ""].joined(separator: "\u{1F}")
    }
    /// What agents may do with the database: not see it, read it, change it once the user allows each change, or change
    /// it freely.
    public enum Access: String, Codable, Sendable, CaseIterable {
        case hidden, read, ask, free
    }
    /// The database's environment, tagged the way TablePlus and TablePro tag theirs. It sets the database's colour
    /// everywhere it shows (green, blue, orange, red). Agents may only read a Production database.
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case local, development, staging, production
    }

    /// The database's name in the project, which `kelp db --db` and the tab's address use.
    public var name: String
    public var engine: Engine
    /// The file the database was found in, relative to the project ("compose.yaml", ".env.production"). nil when the
    /// user added it by hand.
    public var source: String?
    public var host: String?, port: Int?, database: String?, user: String?
    /// The absolute path of a SQLite database's file.
    public var path: String?
    /// Whether to use TLS to the server, in libpq's words: "disable", "require", or "verify-ca" and "verify-full",
    /// which also check the server's certificate (and its name). nil or "prefer" means TLS is used when the server
    /// offers it.
    public var ssl: String?
    /// A host from ~/.ssh/config that the server is reached through, by a port forwarded over Kelp's shared connection.
    public var ssh: String?
    /// The group the database was kept in by the app it was imported from (a TablePlus group, a DBeaver folder). It is
    /// used for "All my projects".
    public var group: String?
    /// Where the password is kept outside Kelp, as another app's keychain item ("<service>\u{1F}<account>"). Kelp reads
    /// it the first time the database is opened (macOS asks once, then) and keeps it in Kelp's own keychain from then
    /// on.
    public var passwordIn: String?
    public var access: Access
    /// True when agents may only read the database, whatever `access` says. It is set for a host that isn't this Mac,
    /// or when the user marked the database Production.
    public var production: Bool
    /// The environment the user (or the app the database came from) set. nil means Production when `production` is
    /// true, and Local otherwise.
    public var environment: Stage?
    /// Set when this is a branch's own copy of another database (`db.copy`). The copy is listed only in that branch's
    /// workspace, where agents use it instead of the original. It is removed along with the workspace.
    public var copy: BranchCopy?

    public var id: String { name }

    public init(
        name: String, engine: Engine, source: String? = nil, host: String? = nil, port: Int? = nil,
        database: String? = nil, user: String? = nil, path: String? = nil, ssl: String? = nil, access: Access = .ask,
        production: Bool = false
    ) {
        self.name = name
        self.engine = engine
        self.source = source
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.path = path
        self.ssl = ssl
        self.access = access
        self.production = production
    }

    public var stage: Stage { production ? .production : environment ?? .local }

    /// Tags the database with `stage`. Production makes it read only for agents, and Staging lowers free access to
    /// asking before each change.
    public mutating func set(stage: Stage) {
        environment = stage
        production = stage == .production
        if stage == .staging, access == .free { access = .ask }
    }

    /// The access agents actually get, because a production database can at most be read.
    public var agentAccess: Access { production && access != .hidden ? .read : access }

    /// The address shown to people, such as "postgres://app@localhost:5432/app_dev" or the SQLite file's path. It never
    /// holds a password.
    public var address: String {
        if engine.isFile { return path ?? "" }
        let who = user.map { $0 + "@" } ?? "", at = (host ?? "localhost") + (port.map { ":\($0)" } ?? "")
        return "\(engine.rawValue)://\(who)\(at)/\(database ?? "")"
    }
}

/// Says what a database copy is a copy of: the original database's name, the workspace the copy is for, and when it
/// was made.
public struct BranchCopy: Codable, Sendable, Equatable {
    public var of: String, worktreeId: String
    public var at: Date
    public init(of: String, worktreeId: String, at: Date) {
        self.of = of
        self.worktreeId = worktreeId
        self.at = at
    }
}

/// The result of a statement: its columns and rows (as text, with nil for NULL), cut at the requested limit.
public struct QueryResult: Codable, Sendable, Equatable {
    /// The id of this result's entry in the database's history (`db.result`).
    public var id: String
    public var columns: [String]
    public var rows: [[String?]]
    /// How many rows the statement returned, which can be more than `rows` holds. Past the limit, rows are counted only
    /// up to `counted`.
    public var total: Int
    /// The number of rows a change touched. nil for a read.
    public var changed: Int?
    public var ms: Int
    /// True when rows were left out for their size, because Kelp keeps at most 1 MB of a result's cells. A larger
    /// `limit` gives no more rows.
    public var cut: Bool?
    /// What an agent's change does to these rows, set when Kelp holds every row whole. The app shows it where the user
    /// is asked about the change, and Undo uses it to put the rows back. It is never sent to the agent.
    public var change: RowChange?
    /// The statements run in one transaction (`kelp db query "a; b"`), each with the number of rows it changed. Either
    /// all of them were kept or none was. nil for a single statement.
    public var statements: [StatementResult]?
    /// How many rows of a result Kelp keeps, and how far it counts rows beyond that. `total` stops at `counted`.
    public static let kept = 1000, counted = 100_000
    public init(id: String, columns: [String], rows: [[String?]], total: Int, changed: Int? = nil, ms: Int) {
        self.id = id
        self.columns = columns
        self.rows = rows
        self.total = total
        self.changed = changed
        self.ms = ms
    }

    /// The indexes of the columns that an update changed in any of its rows. Empty for any other kind of change, and
    /// for an update whose earlier rows aren't known.
    public var changedColumns: [Int] {
        guard let before = change?.before, change?.kind == .update else { return [] }
        return columns.indices.filter { column in
            zip(before, rows).contains { was, now in
                was.indices.contains(column) && now.indices.contains(column) && was[column] != now[column]
            }
        }
    }
}

/// One of several statements run in one transaction.
public struct StatementResult: Codable, Sendable, Equatable {
    public var sql: String
    /// The number of rows the statement changed. nil when it doesn't say, as for a read.
    public var changed: Int?
    public init(sql: String, changed: Int?) {
        self.sql = sql
        self.changed = changed
    }
}

/// What an UPDATE, DELETE or INSERT on one table does to the rows it returned.
public struct RowChange: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// For an update, the rows are as the change leaves them and `before` holds them as they were. For a delete,
        /// they are the rows it removes, and for an insert the rows it adds.
        case update, delete, insert
    }
    public var kind: Kind
    /// The table as the statement names it, quotes included, so it can go back into SQL unchanged.
    public var table: String
    /// The table's primary key columns, when the rows include all of them, so a row can be found again. Empty when
    /// there is no usable key.
    public var key: [String]
    /// For an update, the rows as they were before it, one for each row of the result and in the same order. nil when
    /// they weren't read, because there is no key or the change modifies the key.
    public var before: [[String?]]?
    public init(kind: Kind, table: String, key: [String] = [], before: [[String?]]? = nil) {
        self.kind = kind
        self.table = table
        self.key = key
        self.before = before
    }

    /// The table's name without its quotes, for use in sentences: "orders", "Order Items".
    public var tableName: String { table.filter { !"\"`".contains($0) } }
}

/// A statement run on a project's database, either by an agent (`session`) or by the user.
public struct DatabaseRun: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// Done means the statement ran. Asks means a change waits for the user, and the row of the agent's session
        /// asks. Denied means the user said no, or nobody answered.
        /// Refused means the database is read only for agents. Failed means the database returned an error.
        case done, asks, denied, refused, failed
    }
    public var id: String, database: String, sql: String
    /// The session of the agent that ran the statement. nil when the user ran it.
    public var session: String?
    public var at: Date
    public var state: State
    public var rows: Int?, changed: Int?, ms: Int?
    /// The database's error, or the reason the statement didn't run.
    public var error: String?
    public init(
        id: String, database: String, sql: String, session: String?, at: Date, state: State, rows: Int? = nil,
        changed: Int? = nil, ms: Int? = nil, error: String? = nil
    ) {
        self.id = id
        self.database = database
        self.sql = sql
        self.session = session
        self.at = at
        self.state = state
        self.rows = rows
        self.changed = changed
        self.ms = ms
        self.error = error
    }
}

extension [DatabaseRun] {
    /// The change `session`'s row asks about now: the oldest of its runs that asks, since the row asks its questions
    /// oldest first and runs are listed newest first (`db.activity`). What shows a change to allow shows this one.
    public func asked(by session: String) -> DatabaseRun? { last { $0.session == session && $0.state == .asks } }
}

/// A database's tables, as an agent reads them before it writes a query.
public struct DatabaseSchema: Codable, Sendable, Equatable {
    public var tables: [Table]
    /// The names of the database's own functions ("schema.name" outside the default schema). nil for engines where Kelp
    /// doesn't read functions.
    public var functions: [String]?
    /// The migrations, when the database has a migration tool's table (read with the whole schema only).
    public var migrations: DatabaseMigrations?
    public init(tables: [Table], functions: [String]? = nil, migrations: DatabaseMigrations? = nil) {
        self.tables = tables
        self.functions = functions
        self.migrations = migrations
    }

    public struct Table: Codable, Sendable, Equatable {
        public var name: String
        /// The table's row count: an exact count for SQLite, and the planner's estimate for other engines.
        public var rows: Int?
        public var columns: [Column]
        public var indexes: [String]
        /// "view" for a view (or a materialized view). nil for a table.
        public var kind: String?
        /// The table's size on disk including its indexes, and its comment, when the database reports them.
        public var bytes: Int?, comment: String?
        public init(
            name: String, rows: Int? = nil, columns: [Column] = [], indexes: [String] = [], kind: String? = nil,
            bytes: Int? = nil, comment: String? = nil
        ) {
            self.name = name
            self.rows = rows
            self.columns = columns
            self.indexes = indexes
            self.kind = kind
            self.bytes = bytes
            self.comment = comment
        }
    }

    public struct Column: Codable, Sendable, Equatable {
        public var name: String, type: String
        public var nullable: Bool, primary: Bool
        /// "users.id" for a foreign key, with the table's schema where it has one ("auth.users.id").
        public var references: String?
        public init(name: String, type: String, nullable: Bool, primary: Bool, references: String? = nil) {
            self.name = name
            self.type = type
            self.nullable = nullable
            self.primary = primary
            self.references = references
        }

        /// The table and column `references` names: the column is what follows its last ".".
        public var target: (table: String, column: String)? {
            guard let references, let dot = references.lastIndex(of: "."), dot != references.startIndex else {
                return nil
            }
            return (String(references[..<dot]), String(references[references.index(after: dot)...]))
        }
    }
}
