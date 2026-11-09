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

// MARK: Import

/// An app (or a file of a standard's) on this Mac that keeps database connections Kelp can bring in.
public struct ImportSource: Codable, Sendable, Equatable, Identifiable {
    /// "tableplus", "dbeaver", "datagrip", "sequelace", "beekeeper", "dbgate", "pgpass", "pgservice", "mycnf";
    /// "pgadmin" and "navicat" are read from a file the user picks (their export).
    public var id: String, name: String
    public var count: Int
    public var engines: [DatabaseInfo.Engine]
    /// Where its passwords are: "keychain" (macOS asks for each), "file" (readable without asking: Kelp asks first),
    /// "none" (typed when first used).
    public var passwords: String
    public init(id: String, name: String, count: Int, engines: [DatabaseInfo.Engine], passwords: String) {
        self.id = id
        self.name = name
        self.count = count
        self.engines = engines
        self.passwords = passwords
    }
}

/// The sources found on this Mac, those with something to bring in.
public struct DatabaseImportSources: InternalMethod {
    public static let name = "db.importSources"
    public typealias Result = [ImportSource]
    public init() {}
}

/// One connection as another app keeps it, read as Kelp would keep it.
public struct ImportedDatabase: Codable, Sendable, Equatable, Identifiable {
    /// Its id where it comes from.
    public var id: String
    public var database: DatabaseInfo
    /// What Kelp can't do the same way ("SSH through a password: set SSH by hand"), or why it's Production.
    public var note: String?
    /// Kelp has one at the same address already: off in the list.
    public var known: Bool
    public init(id: String, database: DatabaseInfo, note: String? = nil, known: Bool = false) {
        self.id = id
        self.database = database
        self.note = note
        self.known = known
    }
}

/// What `source` keeps (`file`: the export picked for pgadmin, navicat), without passwords.
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

/// Brings `ids` of `source` into All my projects: a copy, read again with Import Again. `passwords`: taken too (from the
/// keychain, macOS asking for each; or the app's file). `useHere`: also used in the workspace's project.
public struct DatabaseImport: InternalMethod {
    public static let name = "db.import"
    public typealias Result = [DatabaseInfo]
    /// macOS asks the user for each password in the keychain.
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
