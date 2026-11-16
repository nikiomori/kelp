import Foundation

// A project's databases (`db.*`), which agents and the user reach the same way: through kelpd, which holds the
// passwords, runs every statement and keeps who ran what. Agents read in a read-only transaction; a change an agent
// makes is tried and rolled back first, and waits for the user's Allow on the agent's row when the database says so.

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

/// The times kelpd gives a database's work, and what the calls that wait on it (`db.query`, `db.apply`, `db.check`)
/// wait: read by both sides, so a caller is never told "timed out" of a change kelpd still commits.
public enum DatabaseTimes {
    /// A read's time limit, and a change's; the longest a user's read may be given (Settings › Databases).
    public static let read: TimeInterval = 15, write: TimeInterval = 300, longestRead: TimeInterval = 300
    /// A MySQL trial, its rollback included.
    public static let trial: TimeInterval = 60
    /// Asking Postgres whether the role is a superuser (`Databases.query`, for a production database).
    public static let superuser: TimeInterval = 5
    /// What a call takes past its statement's time before it's given up (`DatabaseWire.within`, a client's run).
    public static let slack: TimeInterval = 10
    /// Connecting: Postgres (`connect`), MySQL's handshake, and a KILL QUERY's handshake and then its answer (each
    /// `kill`, what a MySQL call past its time adds); finding a compose service's container (`compose`).
    public static let connect: TimeInterval = 8, handshake: TimeInterval = 10, kill: TimeInterval = 3
    public static let compose: TimeInterval = 15
    /// Reaching a server through SSH (`Databases.reach`): the shared connection opened (20 s) and checked (3 s).
    /// Limit: `ssh -O forward` has no time of its own.
    public static let reach: TimeInterval = 30

    /// One connection's call that runs `seconds` at most, however it's reached: connected, run, given up on and
    /// stopped on the server.
    public static func call(_ seconds: TimeInterval) -> TimeInterval {
        max(connect, handshake + 2 * kill, compose) + seconds + slack
    }

    /// An agent's statement: the superuser check, its try as a read, its trial (MySQL's client asks first whether
    /// it can roll back), the user's answer, the change.
    public static var query: TimeInterval {
        reach + call(superuser) + call(longestRead) + call(read) + call(trial) + DatabaseQuery.answerWithin
            + call(write)
    }
    /// The table's edits in one transaction. Limit: Appwrite's are a request each, with no time for them all.
    public static var apply: TimeInterval { reach + call(write) }
    /// The sheet's check: the tables, the version and the databases, each a call of its own.
    public static var check: TimeInterval { reach + 3 * call(read) }
}

/// Runs one statement. From an agent: a read, in a read-only transaction; a change goes by the database's
/// `agentAccess`, and waits for the user's Allow when it asks. `limit`: the rows sent back (the history keeps more,
/// for the tab).
public struct DatabaseQuery: RPCMethod {
    public static let name = "db.query"
    public typealias Result = QueryResult
    /// An agent's change waits up to ten minutes for an answer (`answerWithin`), then runs up to five (kelpd's write
    /// limit): the caller waits for all of it (`DatabaseTimes.query`), or it's told "timed out" of a change still
    /// made, and a retry makes it twice.
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

/// Adds a database by hand, or changes one (what agents may do, production): by name. A found one keeps its address;
/// `password`, for one added by hand, goes to the login keychain ("" deletes it, nil keeps it). `library`: kept in
/// "All my projects" instead of the workspace's project, where no agent sees it. `container`: a running container's id
/// (`db.containers`) whose environment holds the password.
public struct DatabaseSave: InternalMethod {
    public static let name = "db.save"
    public typealias Result = DatabaseInfo
    public var worktreeId: String, database: DatabaseInfo, password: String?
    public var library: Bool?, container: String?
    /// A new one (Add, not an edit): refused when its name is taken there, not saved over the one that has it.
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

/// Drops a branch's copy (`DatabaseInfo.copy`): its file, or its Postgres database, and Kelp's entry for it. The
/// database it was copied from is the workspace's again.
public struct DatabaseCopyRemove: InternalMethod {
    public static let name = "db.copyRemove"
    public typealias Result = Done
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
