import Core
import Foundation

/// One way Kelp runs statements on a database: an engine in kelpd (SQLite), spoken to over its own protocol at an
/// address (Postgres, MySQL, Appwrite), or through a client program (DuckDB's, or psql and mysql inside the compose
/// container that runs the server). `DatabaseEngines.runner` picks the one for a connection; a new engine is one more
/// conformer and one more case there. What blocks (GRDB, a client run) goes to `off`, never the cooperative pool.
protocol DatabaseRunner: Sendable {
    /// In a read-only transaction (a read-only file): the database itself refuses a change. `timeout`: seconds the
    /// server may take.
    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows
    /// The change made and rolled back: what it touched, and the rows it would leave when it can say (RETURNING).
    func trial(_ sql: String) async throws -> DatabaseRows
    /// `allowed`: the rows the user allowed it to change, committed only if it changes as many (`holdsAllowed`).
    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows
    /// The user's edits, all or none, in one transaction: the rows they changed.
    func apply(_ statements: [String]) async throws -> Int
    func schema() async throws -> DatabaseSchema
    /// Whether `write` holds a change to the rows allowed; else the question says the number is only the trial's.
    var holdsAllowed: Bool { get }
    /// What Add Database's check says of the server: its name and version, its databases. Nil and none where it can't.
    func version() async throws -> String?
    func databases() async throws -> [String]
}

extension DatabaseRunner {
    var holdsAllowed: Bool { true }
    func version() async throws -> String? { nil }
    func databases() async throws -> [String] { [] }
}

extension DatabaseEngines {
    /// The one way to reach `c`: a file's engine, its server's protocol where kelpd reaches an address, else its client
    /// inside the compose container (no address: `host` nil).
    static func runner(_ c: DatabaseConnection, off: Slots) -> any DatabaseRunner {
        switch (c.database.engine, c.database.host) {
        case (.sqlite, _): SQLiteRun(c: c, off: off)
        case (.duckdb, _): DuckDBRun(c: c, off: off)
        case (.appwrite, _): AppwriteWire(c: c)
        case (.postgres, .some): PostgresWire(c: c)
        case (.mysql, .some): MySQLWire(c: c)
        case (.postgres, nil): PostgresRun(c: c, off: off)
        case (.mysql, nil): MySQLRun(c: c, off: off)
        }
    }
}
