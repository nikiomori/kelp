import Foundation

// The methods behind the Add Database sheet: checking an address as it is typed, listing the servers running in Docker,
// and using "All my projects" databases in a project. Only the user may call these, and no agent reaches them.

/// Connects with what the sheet says and reports what is there: the server's version, its tables and its other
/// databases. It throws the server's own words when it can't connect. A nil `password` uses the one kept for
/// `database.name`, if any. `versionOnly` reads only the version (for a tab's capsule) on one connection, without
/// counting tables or listing databases.
public struct DatabaseCheck: InternalMethod {
    public static let name = "db.check"
    public typealias Result = DatabaseCheckResult
    public static var timeout: TimeInterval? { DatabaseTimes.check + DatabaseTimes.slack }
    public var worktreeId: String, database: DatabaseInfo, password: String?
    public var versionOnly: Bool?
    public init(worktreeId: String, database: DatabaseInfo, password: String? = nil, versionOnly: Bool? = nil) {
        self.worktreeId = worktreeId
        self.database = database
        self.password = password
        self.versionOnly = versionOnly
    }
}

public struct DatabaseCheckResult: Codable, Sendable, Equatable {
    /// The engine and version, such as "Postgres 16.4", "MariaDB 10.11.9", "SQLite" or "DuckDB".
    public var version: String
    public var tables: Int
    /// The databases on the server, for the sheet's pop-up menu. Empty for a file database.
    public var databases: [String]
    public var ms: Int
    public init(version: String, tables: Int, databases: [String], ms: Int) {
        self.version = version
        self.tables = tables
        self.databases = databases
        self.ms = ms
    }
}

/// Lists the Postgres, MySQL and MariaDB containers running in Docker that publish their port, which the sheet offers
/// to use.
public struct DatabaseContainers: InternalMethod {
    public static let name = "db.containers"
    public typealias Result = [RunningDatabase]
    public init() {}
}

public struct RunningDatabase: Codable, Sendable, Equatable {
    /// Docker's id and name for the container ("shop-db-1"), and its image ("postgres:16").
    public var container: String, name: String, image: String
    /// The container's address as this Mac reaches it, with the user and database its environment names.
    public var database: DatabaseInfo
    public init(container: String, name: String, image: String, database: DatabaseInfo) {
        self.container = container
        self.name = name
        self.image = image
        self.database = database
    }
}

/// Uses one of the "All my projects" databases in the workspace's project. The project's agents see it from now on, as
/// `access` allows.
public struct DatabaseUse: InternalMethod {
    public static let name = "db.use"
    public typealias Result = DatabaseInfo
    public var worktreeId: String, name: String, access: DatabaseInfo.Access?
    public init(worktreeId: String, name: String, access: DatabaseInfo.Access? = nil) {
        self.worktreeId = worktreeId
        self.name = name
        self.access = access
    }
}

// MARK: Import

/// An app (or a standard file) on this Mac that keeps database connections Kelp can bring in.
public struct ImportSource: Codable, Sendable, Equatable, Identifiable {
    /// "tableplus", "dbeaver", "datagrip", "sequelace", "beekeeper", "dbgate", "pgpass", "pgservice" or "mycnf".
    /// "pgadmin" and "navicat" are read from a file the user picks (their export).
    public var id: String, name: String
    public var count: Int
    public var engines: [DatabaseInfo.Engine]
    /// Where the app keeps its passwords: "keychain" (macOS asks for each one), "file" (readable without asking, so
    /// Kelp asks first), or "none" (the password is typed when first used).
    public var passwords: String
    public init(id: String, name: String, count: Int, engines: [DatabaseInfo.Engine], passwords: String) {
        self.id = id
        self.name = name
        self.count = count
        self.engines = engines
        self.passwords = passwords
    }
}

/// What an import did: the databases it kept, how many came with their passwords, how many will ask for their password
/// when first opened, and the ones it couldn't keep (with the reason).
public struct ImportOutcome: Codable, Sendable, Equatable {
    public var imported: [DatabaseInfo]
    public var withPasswords: Int, later: Int
    /// True when the user answered macOS with Don't Allow, so the rest came without their passwords.
    public var denied: Bool
    public var skipped: [String]
    public init(imported: [DatabaseInfo], withPasswords: Int, later: Int, denied: Bool, skipped: [String]) {
        self.imported = imported
        self.withPasswords = withPasswords
        self.later = later
        self.denied = denied
        self.skipped = skipped
    }
}

/// Lists the import sources found on this Mac that have something to bring in.
public struct DatabaseImportSources: InternalMethod {
    public static let name = "db.importSources"
    public typealias Result = [ImportSource]
    public init() {}
}

/// One connection that another app keeps, read into the form Kelp would keep it in.
public struct ImportedDatabase: Codable, Sendable, Equatable, Identifiable {
    /// The connection's id in the app it comes from.
    public var id: String
    public var database: DatabaseInfo
    /// What Kelp can't do the same way ("SSH through a password: set SSH by hand"), or why the database is Production.
    public var note: String?
    /// True when Kelp already has a database at the same address, so it is unchecked in the list.
    public var known: Bool
    public init(id: String, database: DatabaseInfo, note: String? = nil, known: Bool = false) {
        self.id = id
        self.database = database
        self.note = note
        self.known = known
    }
}

/// Reads the connections that `source` keeps, without passwords. `file` is the export picked for pgadmin or navicat.
public struct DatabaseImportRead: InternalMethod {
    public static let name = "db.importRead"
    public typealias Result = [ImportedDatabase]
    public var worktreeId: String, source: String, file: String?
    public init(worktreeId: String, source: String, file: String? = nil) {
        self.worktreeId = worktreeId
        self.source = source
        self.file = file
    }
}

/// Brings the connections `ids` of `source` into All my projects as copies, which Import Again reads again. With
/// `passwords`, the passwords are taken now, from the app's file or its keychain (macOS asks for each). Without it, a
/// password in another app's keychain is read when the database is first opened (`DatabaseInfo.passwordIn`). With
/// `useHere`, the databases are also used in the workspace's project.
public struct DatabaseImport: InternalMethod {
    public static let name = "db.import"
    public typealias Result = ImportOutcome
    /// The long timeout is because macOS asks the user for each password in the keychain.
    public static var timeout: TimeInterval? { 600 }
    public var worktreeId: String, source: String, file: String?, ids: [String]
    public var passwords: Bool, useHere: Bool
    public init(
        worktreeId: String, source: String, file: String? = nil, ids: [String], passwords: Bool, useHere: Bool
    ) {
        self.worktreeId = worktreeId
        self.source = source
        self.file = file
        self.ids = ids
        self.passwords = passwords
        self.useHere = useHere
    }
}

// MARK: The panel's dots

/// Checks whether each of the workspace's databases answers, trying each once with a short limit. It never dials a
/// remote host, so a database behind an SSH host, or one in a remote project with no open connection, reports that
/// instead.
public struct DatabaseStatus: InternalMethod {
    public static let name = "db.status"
    public typealias Result = [DatabaseHealth]
    public static var timeout: TimeInterval? { 30 }
    /// `library` checks the All My Projects databases instead of the project's.
    public var worktreeId: String, library: Bool?
    public init(worktreeId: String, library: Bool? = nil) {
        self.worktreeId = worktreeId
        self.library = library
    }
}

public struct DatabaseHealth: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// Ok means the database answered. Stopped means its compose service isn't running (`db.start` starts it). Down
        /// means it didn't answer, or refused (`reason`). Unknown means it wasn't tried (a host over SSH with no
        /// connection open).
        case ok, stopped, down, unknown
    }
    public var name: String, state: State
    public var reason: String?
    public init(name: String, state: State, reason: String? = nil) {
        self.name = name
        self.state = state
        self.reason = reason
    }
}

/// Starts the compose service a database runs in (`docker compose up -d <service>`).
public struct DatabaseStart: InternalMethod {
    public static let name = "db.start"
    public typealias Result = Done
    public static var timeout: TimeInterval? { 180 }
    public var worktreeId: String, name: String
    public init(worktreeId: String, name: String) {
        self.worktreeId = worktreeId
        self.name = name
    }
}

// MARK: The tab's edits

/// Applies the user's edits to a table (UPDATE, INSERT, DELETE by its key) in one transaction, so either every edit is
/// kept or none is. Only the user may call it. An agent changes a database through `db.query`, which asks first.
public struct DatabaseApply: InternalMethod {
    public static let name = "db.apply"
    public typealias Result = QueryResult
    public static var timeout: TimeInterval? { DatabaseTimes.apply + DatabaseTimes.slack }
    public var worktreeId: String, database: String, statements: [String]
    /// How many rows each statement must change, or else none of the edits is kept. Undo This Change sets 1, so each
    /// row must still be as it was when checked.
    public var each: Int?
    public init(worktreeId: String, database: String, statements: [String], each: Int? = nil) {
        self.worktreeId = worktreeId
        self.database = database
        self.statements = statements
        self.each = each
    }
}
