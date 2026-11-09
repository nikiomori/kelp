import Foundation

// Add Database's sheet: an address checked as it's typed, the servers running in Docker, and "All my projects" used
// in a project. The user's only: no agent reaches these.

/// Connects with what the sheet says and tells what's there: the server's version, its tables, its other databases.
/// Throws the server's own words when it can't. `password` nil: the one kept for `database.name`, if any.
public struct DatabaseCheck: InternalMethod {
    public static let name = "db.check"
    public typealias Result = DatabaseCheckResult
    public static var timeout: TimeInterval? { 30 }
    public var worktreeId: String, database: DatabaseInfo, password: String?
    public init(worktreeId: String, database: DatabaseInfo, password: String? = nil) {
        self.worktreeId = worktreeId
        self.database = database
        self.password = password
    }
}

public struct DatabaseCheckResult: Codable, Sendable, Equatable {
    /// "Postgres 16.4", "MariaDB 10.11.9", "SQLite", "DuckDB".
    public var version: String
    public var tables: Int
    /// The server's databases, for the sheet's pop-up; empty for a file.
    public var databases: [String]
    public var ms: Int
    public init(version: String, tables: Int, databases: [String], ms: Int) {
        self.version = version
        self.tables = tables
        self.databases = databases
        self.ms = ms
    }
}

/// Postgres, MySQL and MariaDB containers running in Docker that publish their port: what the sheet offers to use.
public struct DatabaseContainers: InternalMethod {
    public static let name = "db.containers"
    public typealias Result = [RunningDatabase]
    public init() {}
}

public struct RunningDatabase: Codable, Sendable, Equatable {
    /// Docker's id and name for it ("shop-db-1"), and its image ("postgres:16").
    public var container: String, name: String, image: String
    /// Its address as this Mac reaches it, the user and database its environment names.
    public var database: DatabaseInfo
    public init(container: String, name: String, image: String, database: DatabaseInfo) {
        self.container = container
        self.name = name
        self.image = image
        self.database = database
    }
}

/// One of "All my projects" used in the workspace's project: its agents see it from now on, as `access` says.
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
