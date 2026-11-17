import Core
import Foundation

/// A way Kelp runs statements on one database. Kelp runs the engine inside kelpd (SQLite), speaks the server's own
/// protocol at its address (Postgres, MySQL, Appwrite), or runs a client program (DuckDB's own, or psql and mysql
/// inside the compose container that runs the server). `DatabaseEngines.runner` picks the runner for a connection, so
/// a new engine is one more conformer and one more case there. Work that blocks (GRDB, a client run) goes to the
/// `off` slots, never to the cooperative pool.
protocol DatabaseRunner: Sendable {
    /// Runs `sql` in a read-only transaction (or on a file opened read-only), so the database itself refuses a
    /// change. `timeout` is the number of seconds the server may take.
    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows
    /// Makes the change and rolls it back. Returns how many rows it touched, and the rows it would leave when the
    /// engine can say so (RETURNING).
    func trial(_ sql: String) async throws -> DatabaseRows
    /// Makes a change. `allowed` is the number of rows the user allowed it to change, and the change is committed
    /// only if it changes that many (see `holdsAllowed`).
    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows
    /// Runs the user's edits in one transaction, so all of them are kept or none. Returns how many rows they changed.
    func apply(_ statements: [String]) async throws -> Int
    /// Runs several statements in one transaction and returns how many rows each one changed (nil for a read). The
    /// transaction is kept when `keep` approves those counts (a trial keeps none) and rolled back otherwise. A runner
    /// that can't run a batch throws.
    func batch(_ statements: [String], keep: @escaping @Sendable ([Int?]) -> Bool) async throws -> [Int?]
    func schema() async throws -> DatabaseSchema
    /// Whether `write` holds a change to the number of rows allowed. When it doesn't, the question put to the user
    /// says the number is only what the trial changed.
    var holdsAllowed: Bool { get }
    /// What the check in Add Database shows about the server: its name and version, and its databases. A runner that
    /// can't tell returns nil and an empty list.
    func version() async throws -> String?
    func databases() async throws -> [String]
}

extension DatabaseRunner {
    var holdsAllowed: Bool { true }
    /// Limit: SQLite and the servers kelpd talks to directly run a batch; a client program and Appwrite don't yet.
    func batch(_ statements: [String], keep: @escaping @Sendable ([Int?]) -> Bool) async throws -> [Int?] {
        throw DatabaseFailure.noBatch
    }
    func version() async throws -> String? { nil }
    func databases() async throws -> [String] { [] }
}

extension DatabaseEngines {
    /// Picks, in one place, how to reach a connection's database. A file database uses its own engine. A server
    /// with an address is reached over its own protocol, and a server without one (`host` is nil) through its client
    /// inside the compose container.
    static func runner(_ databaseConnection: DatabaseConnection, off: Slots) -> any DatabaseRunner {
        switch (databaseConnection.database.engine, databaseConnection.database.host) {
        case (.sqlite, _): SQLiteRun(connection: databaseConnection, off: off)
        case (.duckdb, _): DuckDBRun(connection: databaseConnection, off: off)
        case (.appwrite, _): AppwriteWire(connection: databaseConnection)
        case (.postgres, .some): PostgresWire(connection: databaseConnection)
        case (.mysql, .some): MySQLWire(connection: databaseConnection)
        case (.postgres, nil): PostgresRun(connection: databaseConnection, off: off)
        case (.mysql, nil): MySQLRun(connection: databaseConnection, off: off)
        }
    }
}
