import Foundation

// A project's databases (`db.*`), which agents and the user reach the same way: through kelpd, which holds the
// passwords, runs every statement and keeps who ran what. Agents read in a read-only transaction; a change an agent
// makes is tried and rolled back first, and waits for the user's Allow on the agent's row when the database says so.

/// A database of a project: found in its files (compose, .env, database.yml, a SQLite file) or added by hand.
/// A database's tab: `db:<workspace>/<name>`, with one run (`?run=`) or table (`?table=`) shown; the name and the table
/// percent-encoded (an imported name may hold a "?" or "/"). The one builder of it: the tab, the agent's row,
/// `kelp db`.
public enum DatabaseTabURI {
    public static func uri(worktree: String, name: String, run: String? = nil, table: String? = nil) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?/")
        let name = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let table = table.map { "?table=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) }
        return "db:\(worktree)/\(name)" + (run.map { "?run=" + $0 } ?? table ?? "")
    }
}

public struct DatabaseInfo: Codable, Sendable, Equatable, Identifiable {
    public enum Engine: String, Codable, Sendable, CaseIterable {
        /// Appwrite: a project's database over its REST API (host: the endpoint, user: the project's ID, password: an
        /// API key), its rows read and changed by a narrow SQL Kelp translates.
        case sqlite, postgres, mysql, duckdb, appwrite

        /// A file on disk rather than a server.
        public var isFile: Bool { self == .sqlite || self == .duckdb }
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
    public init(id: String, columns: [String], rows: [[String?]], total: Int, changed: Int? = nil, ms: Int) {
        self.id = id
        self.columns = columns
        self.rows = rows
        self.total = total
        self.changed = changed
        self.ms = ms
    }
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

/// The databases of the workspace's project: found in its files, and those added by hand. An agent isn't told of one
/// hidden from agents.
public struct DatabaseList: RPCMethod {
    public static let name = "db.list"
    public typealias Result = [DatabaseInfo]
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// Its tables; with `table`, only that one.
public struct DatabaseSchemaRead: RPCMethod {
    public static let name = "db.schema"
    public typealias Result = DatabaseSchema
    public var worktreeId: String, database: String, table: String?
    public init(worktreeId: String, database: String, table: String? = nil) {
        self.worktreeId = worktreeId
        self.database = database
        self.table = table
    }
}

/// Runs one statement. From an agent: a read, in a read-only transaction; a change goes by the database's
/// `agentAccess`,
/// and waits for the user's Allow when it asks. `limit`: the rows sent back (the history keeps more, for the tab).
public struct DatabaseQuery: RPCMethod {
    public static let name = "db.query"
    public typealias Result = QueryResult
    /// An agent's change waits up to ten minutes for an answer (`answerWithin`), then runs up to five (kelpd's write
    /// limit): the caller waits for both, or it's told "timed out" of a change still made, and a retry makes it twice.
    public static var timeout: TimeInterval? { answerWithin + 300 + 60 }
    public static let answerWithin: TimeInterval = 600
    public var worktreeId: String, database: String, sql: String, limit: Int?
    public init(worktreeId: String, database: String, sql: String, limit: Int? = nil) {
        self.worktreeId = worktreeId
        self.database = database
        self.sql = sql
        self.limit = limit
    }
}

/// Adds a database by hand, or changes one (what agents may do, production): by name. A found one keeps its address;
/// `password`, for one added by hand, goes to the login keychain ("" deletes it, nil keeps it). `library`: kept in
/// "All my projects" instead of the workspace's project, where no agent sees it. `container`: a running container's id
/// (`db.containers`) whose environment holds the password.
public struct DatabaseSave: InternalMethod {
    public static let name = "db.save"
    public typealias Result = DatabaseInfo
    public var worktreeId: String, database: DatabaseInfo, password: String?
    public var library: Bool?, container: String?
    public init(
        worktreeId: String, database: DatabaseInfo, password: String? = nil, library: Bool? = nil,
        container: String? = nil
    ) {
        self.worktreeId = worktreeId
        self.database = database
        self.password = password
        self.library = library
        self.container = container
    }
}

/// Forgets one added by hand and its password; a found one goes back to how it was found. `library`: one of "All my
/// projects".
public struct DatabaseRemove: InternalMethod {
    public static let name = "db.remove"
    public typealias Result = Done
    public var worktreeId: String, name: String, library: Bool?
    public init(worktreeId: String, name: String, library: Bool? = nil) {
        self.worktreeId = worktreeId
        self.name = name
        self.library = library
    }
}

/// A copy of a database for the workspace's branch, to change without touching the project's own: a SQLite file goes into
/// the branch's folder (where Kelp finds it under the same name), a Postgres on this Mac becomes `<database>_<branch>`
/// (CREATE DATABASE … TEMPLATE, which needs nobody connected to it). Not a production one, MySQL's, or a remote host's.
public struct DatabaseCopy: InternalMethod {
    public static let name = "db.copy"
    public typealias Result = DatabaseInfo
    public var worktreeId: String, database: String
    public init(worktreeId: String, database: String) {
        self.worktreeId = worktreeId
        self.database = database
    }
}

/// What the Databases panel shows: the databases and what was run on them lately.
public struct DatabaseActivity: InternalMethod {
    public static let name = "db.activity"
    public typealias Result = DatabasesEvent
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// A run's rows, kept for the tab (a change that asks: the rows it would leave); nil once it's gone from what's kept.
public struct DatabaseResultRead: InternalMethod {
    public static let name = "db.result"
    public typealias Result = QueryResult?
    public var worktreeId: String, id: String
    public init(worktreeId: String, id: String) {
        self.worktreeId = worktreeId
        self.id = id
    }
}

/// A watched workspace's databases and their latest runs, newest first: pushed when one runs or a database changes.
public struct DatabasesEvent: RPCEvent, Equatable {
    public static let name = "event.databases"
    public var worktree: String, databases: [DatabaseInfo], runs: [DatabaseRun]
    /// "All my projects": the user's own, which no agent sees until one is used in a project (`db.use`).
    public var library: [DatabaseInfo]?
    public init(worktree: String, databases: [DatabaseInfo], runs: [DatabaseRun], library: [DatabaseInfo]? = nil) {
        self.worktree = worktree
        self.databases = databases
        self.runs = runs
        self.library = library
    }
}
