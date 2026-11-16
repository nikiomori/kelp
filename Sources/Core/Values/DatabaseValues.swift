import Foundation

// A project's databases as values: what kelpd finds, runs and keeps, and the app shows (`db.*` in DatabaseMethods).

/// A database's tab: `db:<workspace>/<name>`, with one run (`?run=`) or table (`?table=`) shown; the name and the table
/// percent-encoded (an imported name may hold a "?" or "/"). The one builder of it: the tab, the agent's row,
/// `kelp db`. And the one reader (`parts`): the daemon decides whether an agent may open a tab by the workspace and
/// database the tab will show, so the two read an address alike.
public enum DatabaseTabURI {
    /// The workspace and database `uri` names, and what follows its "?"; nil when it isn't a database tab's.
    public static func parts(_ uri: String) -> (worktree: String, name: String, query: String?)? {
        guard let colon = uri.firstIndex(of: ":"), uri[..<colon].lowercased() == "db" else { return nil }
        let body = uri[uri.index(after: colon)...].split(separator: "?", maxSplits: 1)
        let parts = body.first?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1].removingPercentEncoding ?? parts[1], body.count > 1 ? String(body[1]) : nil)
    }

    public static func uri(worktree: String, name: String, run: String? = nil, table: String? = nil) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?/")
        let name = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let table = table.map { "?table=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) }
        return "db:\(worktree)/\(name)" + (run.map { "?run=" + $0 } ?? table ?? "")
    }
}

/// A database of a project: found in its files (compose, .env, database.yml, a SQLite file) or added by hand.
public struct DatabaseInfo: Codable, Sendable, Equatable, Identifiable {
    public enum Engine: String, Codable, Sendable, CaseIterable {
        /// Appwrite: a project's database over its REST API (host: the endpoint, user: the project's ID, password: an
        /// API key), its rows read and changed by a narrow SQL Kelp translates.
        case sqlite, postgres, mysql, duckdb, appwrite

        /// A file on disk rather than a server.
        public var isFile: Bool { self == .sqlite || self == .duckdb }

        /// The port its server takes unless told another: nil for a file, and for Appwrite's endpoint (a URL's).
        public var defaultPort: Int? {
            switch self {
            case .postgres: 5432
            case .mysql: 3306
            case .sqlite, .duckdb, .appwrite: nil
            }
        }

        /// Its name wherever Kelp says it: "Postgres · compose.yaml", a check's "SQLite".
        public var displayName: String {
            switch self {
            case .sqlite: "SQLite"
            case .postgres: "Postgres"
            case .mysql: "MySQL"
            case .duckdb: "DuckDB"
            case .appwrite: "Appwrite"
            }
        }

        /// What its SQL quotes a name in: "orders", `orders` in MySQL.
        public var identifierQuote: Character { self == .mysql ? "`" : "\"" }

        /// The engine a container image runs, by its name (not its registry's or owner's): postgres:16,
        /// bitnami/postgresql, timescale/timescaledb-ha, mariadb, percona-server; nil for others.
        public init?(image: String) {
            let last = image.lowercased().split(separator: "/").last ?? ""
            let name = last.split(whereSeparator: { $0 == ":" || $0 == "@" }).first ?? ""
            if ["postgres", "postgis", "timescale", "pgvector"].contains(where: name.contains) {
                self = .postgres
            } else if ["mysql", "mariadb", "percona"].contains(where: name.contains) {
                self = .mysql
            } else {
                return nil
            }
        }
    }

    /// A host that is this Mac (or its Docker's): a loopback address, or this Mac's own name. Not any `.local` name
    /// (whoever answers for it on the network) nor a name without a dot (a compose service's, a search domain's host).
    public static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "::1", "0.0.0.0", "host.docker.internal", thisMac].contains(host)
            || host.hasPrefix("127.") || host.hasSuffix(".localhost")
    }

    /// gethostname, not ProcessInfo.hostName: no DNS lookup.
    private static let thisMac: String = {
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, name.count) == 0 else { return "localhost" }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
    }()

    /// Where it is, as one key: the same file, or the same server (this Mac's under any of its names), port, database
    /// and SSH host. Two entries with one place are one database: what the user said of one holds for the other.
    public var place: String {
        if engine.isFile { return [engine.rawValue, path ?? ""].joined(separator: "\u{1F}") }
        let at = host.map { Self.isLocal($0) ? "localhost" : $0.lowercased() } ?? ""
        return [engine.rawValue, at, port.map(String.init) ?? "", database ?? "", ssh ?? ""].joined(separator: "\u{1F}")
    }
    /// What agents may do with it: not see it, read it, change it once the user allows each change, change it freely.
    public enum Access: String, Codable, Sendable, CaseIterable {
        case hidden, read, ask, free
    }
    /// Which kind of database it is, as TablePlus and TablePro tag theirs: its colour everywhere it shows (green, blue,
    /// orange, red). Production is the one agents only read.
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case local, development, staging, production
    }

    /// Its name in the project: what `kelp db --db` and the tab's address use.
    public var name: String
    public var engine: Engine
    /// The file it was found in, relative to the project ("compose.yaml", ".env.production"); nil: added by hand.
    public var source: String?
    public var host: String?, port: Int?, database: String?, user: String?
    /// A SQLite database's file, absolute.
    public var path: String?
    /// TLS to the server, libpq's words: "disable", "require"; nil or "prefer": when the server offers it.
    public var ssl: String?
    /// A host of ~/.ssh/config the server is reached through (a port forwarded over Kelp's shared connection).
    public var ssh: String?
    /// The group it was kept in where it came from (TablePlus' group, DBeaver's folder), for "All my projects".
    public var group: String?
    /// Where its password still is, outside Kelp: another app's keychain item ("<service>\u{1F}<account>"), read the
    /// first time the database is opened (macOS asks then, once) and kept in Kelp's own from there.
    public var passwordIn: String?
    public var access: Access
    /// Agents only read it, whatever `access` says: on a host that isn't this Mac, or named so.
    public var production: Bool
    /// Its environment as the user (or the app it came from) said; nil: Production when `production`, else Local.
    public var environment: Stage?
    /// A branch's own copy of another database (`db.copy`): listed in that branch's workspace only, where agents use
    /// it before the one it was copied from; it goes with the workspace.
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

    /// Tagged `stage`: Production is read only for agents; Staging asks before a change at most.
    public mutating func set(stage: Stage) {
        environment = stage
        production = stage == .production
        if stage == .staging, access == .free { access = .ask }
    }

    /// What agents get: a production database is read at most.
    public var agentAccess: Access { production && access != .hidden ? .read : access }

    /// "postgres://app@localhost:5432/app_dev", or the SQLite file: never a password.
    public var address: String {
        if engine.isFile { return path ?? "" }
        let who = user.map { $0 + "@" } ?? "", at = (host ?? "localhost") + (port.map { ":\($0)" } ?? "")
        return "\(engine.rawValue)://\(who)\(at)/\(database ?? "")"
    }
}

/// Whose copy a database is: the database it was copied from, by name, the workspace it's for, and when.
public struct BranchCopy: Codable, Sendable, Equatable {
    public var of: String, worktreeId: String
    public var at: Date
    public init(of: String, worktreeId: String, at: Date) {
        self.of = of
        self.worktreeId = worktreeId
        self.at = at
    }
}

/// What a statement gave: its columns and rows (text, nil for NULL), cut at the asked limit.
public struct QueryResult: Codable, Sendable, Equatable {
    /// Its entry in the database's history (`db.result`).
    public var id: String
    public var columns: [String]
    public var rows: [[String?]]
    /// The rows it gave, `rows` or more: past the limit they're counted only up to what Kelp keeps.
    public var total: Int
    /// Rows a change touched; nil for a read.
    public var changed: Int?
    public var ms: Int
    /// Rows left out for their size (past what Kelp keeps of a result's cells, 1 MB): a larger `limit` gives no more.
    public var cut: Bool?
    /// What an agent's change does to these rows, when Kelp holds every one of them whole: shown where it's asked,
    /// and what Undo puts back. Never sent to the agent.
    public var change: RowChange?
    /// Several statements run in one transaction (`kelp db query "a; b"`), each with the rows it changed: all of
    /// them were kept, or none. nil: one statement.
    public var statements: [StatementResult]?
    /// Rows kept of a result, and how far they're counted past that: `total` stops there.
    public static let kept = 1000, counted = 100_000
    public init(id: String, columns: [String], rows: [[String?]], total: Int, changed: Int? = nil, ms: Int) {
        self.id = id
        self.columns = columns
        self.rows = rows
        self.total = total
        self.changed = changed
        self.ms = ms
    }

    /// The columns an update changed in any of its rows, by index: none for another change, or one whose rows as
    /// they were aren't known.
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
    /// Rows it changed; nil: it doesn't say (a read).
    public var changed: Int?
    public init(sql: String, changed: Int?) {
        self.sql = sql
        self.changed = changed
    }
}

/// What one table's UPDATE, DELETE or INSERT does to the rows it returned.
public struct RowChange: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The rows are as the change leaves them (`before`: as they were); the rows it removes; the rows it adds.
        case update, delete, insert
    }
    public var kind: Kind
    /// The table, as the statement names it, its quotes and all: it goes into SQL as it is.
    public var table: String
    /// Its primary key's columns, when the rows have them all: what finds a row again. Empty: none.
    public var key: [String]
    /// An update's rows as they were, one per row of the result in its order; nil: not read (no key, or the change
    /// moves it).
    public var before: [[String?]]?
    public init(kind: Kind, table: String, key: [String] = [], before: [[String?]]? = nil) {
        self.kind = kind
        self.table = table
        self.key = key
        self.before = before
    }

    /// The table's name without its quotes, for words: "orders", "Order Items".
    public var tableName: String { table.filter { !"\"`".contains($0) } }
}

/// A statement run on a project's database, by an agent (`session`) or the user.
public struct DatabaseRun: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// It ran. Asks: a change waits for the user (`session`'s row asks). Denied: the user said no, or nobody
        /// answered.
        /// Refused: the database is read only for agents. Failed: the database's error.
        case done, asks, denied, refused, failed
    }
    public var id: String, database: String, sql: String
    /// The agent's session; nil: the user's.
    public var session: String?
    public var at: Date
    public var state: State
    public var rows: Int?, changed: Int?, ms: Int?
    /// The database's error, or why it didn't run.
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

/// A database's tables, as an agent reads them before it writes a query.
public struct DatabaseSchema: Codable, Sendable, Equatable {
    public var tables: [Table]
    /// The database's own functions, by name ("schema.name" outside the default schema); nil where Kelp doesn't read them.
    public var functions: [String]?
    public init(tables: [Table], functions: [String]? = nil) {
        self.tables = tables
        self.functions = functions
    }

    public struct Table: Codable, Sendable, Equatable {
        public var name: String
        /// Its rows: counted for SQLite, the planner's estimate elsewhere.
        public var rows: Int?
        public var columns: [Column]
        public var indexes: [String]
        /// "view" for a view (or a materialized one); nil: a table.
        public var kind: String?
        /// Its size on disk with its indexes, and its comment, where the database says them.
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
        /// "users.id" for a foreign key.
        public var references: String?
        public init(name: String, type: String, nullable: Bool, primary: Bool, references: String? = nil) {
            self.name = name
            self.type = type
            self.nullable = nullable
            self.primary = primary
            self.references = references
        }
    }
}
