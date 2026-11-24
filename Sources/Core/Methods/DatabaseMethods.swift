import Foundation

// A project's databases (`db.*`). Agents and the user reach them the same way, through kelpd, which holds the
// passwords, runs every statement and records who ran what. Agents read in a read-only transaction. A change an agent
// makes is first tried and rolled back, and it waits for the user's Allow on the agent's row when the database's
// access says so.

/// Lists the databases of the workspace's project: those found in its files, and those added by hand. An agent isn't
/// told about a database hidden from agents.
public struct DatabaseList: RPCMethod {
    public static let name = "db.list"
    public typealias Result = [DatabaseInfo]
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// Returns the database's tables, or with `table`, only that table.
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

/// The time limits kelpd gives a database's work, and how long the calls that wait on it (`db.query`, `db.apply`,
/// `db.check`) wait. Both sides read them, so a caller is never told "timed out" about a change that kelpd still
/// commits.
public enum DatabaseTimes {
    /// The time limit for a read and for a change, and the longest a user's read may be given (Settings › Databases).
    public static let read: TimeInterval = 15, write: TimeInterval = 300, longestRead: TimeInterval = 300
    /// The time limit for a MySQL trial, including its rollback.
    public static let trial: TimeInterval = 60
    /// The time limit for asking Postgres whether the role is a superuser (`Databases.query`, for a production
    /// database).
    public static let superuser: TimeInterval = 5
    /// How much longer than its statement's time limit a call may take before it is given up (`DatabaseWire.within`, a
    /// client's run).
    public static let slack: TimeInterval = 10
    /// Time limits for connecting: to Postgres (`connect`), for MySQL's handshake, and for a KILL QUERY's handshake and
    /// its answer (each `kill`, which a MySQL call past its time adds). `compose` is the limit for finding a compose
    /// service's container.
    public static let connect: TimeInterval = 8, handshake: TimeInterval = 10, kill: TimeInterval = 3
    public static let compose: TimeInterval = 15
    /// The time limit for reaching a server through SSH (`Databases.reach`): opening the shared connection (20 s) and
    /// checking it (3 s).
    /// Limit: `ssh -O forward` has no time of its own.
    public static let reach: TimeInterval = 30

    /// Returns the time limit for one connection's call that runs at most `seconds`, covering connecting, running, and
    /// giving up and stopping the statement on the server.
    public static func call(_ seconds: TimeInterval) -> TimeInterval {
        max(connect, handshake + 2 * kill, compose) + seconds + slack
    }

    /// The sum of the time limits for each step of an agent's statement: the superuser check, trying it as a read, its
    /// trial (MySQL's client asks first whether it can roll back), the user's answer, and the change.
    public static var query: TimeInterval {
        reach + call(superuser) + call(longestRead) + call(read) + call(trial) + DatabaseQuery.answerWithin
            + call(write)
    }
    /// The time limit for applying the table's edits in one transaction. Limit: Appwrite's edits are one request each,
    /// and this time doesn't stretch to cover all of them.
    public static var apply: TimeInterval { reach + call(write) }
    /// The time limit for the sheet's check: the tables, the version and the databases, each a call of its own.
    public static var check: TimeInterval { reach + 3 * call(read) }
}

/// Runs one statement. From an agent, a read runs in a read-only transaction, and a change follows the database's
/// `agentAccess` and waits for the user's Allow when that says to ask. `limit` is the number of rows sent back. The
/// history keeps more, for the tab.
public struct DatabaseQuery: RPCMethod {
    public static let name = "db.query"
    public typealias Result = QueryResult
    /// An agent's change waits up to ten minutes for an answer (`answerWithin`), then runs for up to five (kelpd's
    /// write limit). The caller waits for all of it (`DatabaseTimes.query`). Otherwise it would be told "timed out"
    /// about a change that is still made, and a retry would make it twice.
    public static var timeout: TimeInterval? { DatabaseTimes.query + DatabaseTimes.slack }
    public static let answerWithin: TimeInterval = 600
    public var worktreeId: String, database: String, sql: String, limit: Int?
    public init(worktreeId: String, database: String, sql: String, limit: Int? = nil) {
        self.worktreeId = worktreeId
        self.database = database
        self.sql = sql
        self.limit = limit
    }
}

/// Adds a database by hand, or changes one by name (what agents may do, production). A found database keeps its
/// address. For a database added by hand, `password` goes to the login keychain ("" deletes it, nil keeps it). With
/// `library`, the database is kept in "All my projects" instead of the workspace's project, where no agent sees it.
/// `container` is a running container's id (`db.containers`) whose environment holds the password.
public struct DatabaseSave: InternalMethod {
    public static let name = "db.save"
    public typealias Result = DatabaseInfo
    public var worktreeId: String, database: DatabaseInfo, password: String?
    public var library: Bool?, container: String?
    /// True for a new database (Add, not an edit). It is refused when its name is already taken, instead of being saved
    /// over the database that has the name.
    public var adding: Bool?
    public init(
        worktreeId: String, database: DatabaseInfo, password: String? = nil, library: Bool? = nil,
        container: String? = nil, adding: Bool? = nil
    ) {
        self.worktreeId = worktreeId
        self.database = database
        self.password = password
        self.library = library
        self.container = container
        self.adding = adding
    }
}

/// Forgets a database added by hand, with its password. A found database goes back to how it was found. With
/// `library`, the database is one of "All my projects".
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

/// Makes a copy of a database for the workspace's branch, to change without touching the project's own database. A
/// SQLite file is copied into the branch's folder, where Kelp finds it under the same name. A Postgres database on this
/// Mac is copied to `<database>_<branch>` with CREATE DATABASE … TEMPLATE, which needs nobody connected to the
/// original. Production databases, MySQL databases and databases on a remote host can't be copied.
public struct DatabaseCopy: InternalMethod {
    public static let name = "db.copy"
    public typealias Result = DatabaseInfo
    public var worktreeId: String, database: String
    public init(worktreeId: String, database: String) {
        self.worktreeId = worktreeId
        self.database = database
    }
}

/// Drops a branch's copy of a database (`DatabaseInfo.copy`): its file or its Postgres database, and Kelp's entry for
/// it. The original database becomes the workspace's database again.
public struct DatabaseCopyRemove: InternalMethod {
    public static let name = "db.copyRemove"
    public typealias Result = Done
    public var worktreeId: String, database: String
    public init(worktreeId: String, database: String) {
        self.worktreeId = worktreeId
        self.database = database
    }
}

/// Compares a branch's copy of a database (`DatabaseInfo.copy`) with the database it copies: each table's columns and
/// number of rows. `database` names the copy; nil means the workspace's only copy. Agents compare only what they may
/// read.
public struct DatabaseDiff: RPCMethod {
    public static let name = "db.diff"
    public typealias Result = DatabaseComparison
    public var worktreeId: String, database: String?
    public init(worktreeId: String, database: String? = nil) {
        self.worktreeId = worktreeId
        self.database = database
    }
}

/// Returns what the Databases panel shows: the databases and what was run on them lately.
public struct DatabaseActivity: InternalMethod {
    public static let name = "db.activity"
    public typealias Result = DatabasesEvent
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// Returns a run's rows, kept for the tab. For a change that asks first, these are the rows it would leave. nil once
/// the run is no longer kept.
public struct DatabaseResultRead: InternalMethod {
    public static let name = "db.result"
    public typealias Result = QueryResult?
    public var worktreeId: String, id: String
    public init(worktreeId: String, id: String) {
        self.worktreeId = worktreeId
        self.id = id
    }
}

/// A watched workspace's databases and their latest runs, newest first. It is pushed when a statement runs or a
/// database changes.
public struct DatabasesEvent: RPCEvent, Equatable {
    public static let name = "event.databases"
    public var worktree: String, databases: [DatabaseInfo], runs: [DatabaseRun]
    /// The "All my projects" databases, the user's own, which no agent sees until one is used in a project
    /// (`db.use`).
    public var library: [DatabaseInfo]?
    /// Why the databases couldn't be read, when they couldn't: there are none in the event then.
    public var error: String?
    /// How many migrations each database hasn't applied, by name, for those whose schema was read since kelpd started
    /// (`DatabaseSchema.migrations`).
    public var migrations: [String: Int]?
    public init(
        worktree: String, databases: [DatabaseInfo], runs: [DatabaseRun], library: [DatabaseInfo]? = nil,
        error: String? = nil, migrations: [String: Int]? = nil
    ) {
        self.worktree = worktree
        self.databases = databases
        self.runs = runs
        self.library = library
        self.error = error
        self.migrations = migrations
    }
}
