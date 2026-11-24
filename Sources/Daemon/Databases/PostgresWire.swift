import Core
import Foundation
import NIOSSL
import PostgresNIO
import os

// Reads, writes and schema for Postgres, spoken by kelpd itself (PostgresNIO) over a new connection for each call.

struct PostgresWire: DatabaseRunner {
    let connection: DatabaseConnection
    /// How long a read may run past the server's own limit before its connection is closed.
    var grace: TimeInterval = 10

    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        try await Self.with(connection, within: timeout + grace) { conn in
            try await Self.run(conn, "BEGIN TRANSACTION READ ONLY")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(timeout))s'")
            return try await Self.rows(conn, sql)
        }
    }

    /// Makes the change and rolls it back. With RETURNING, the rows it returns are the rows it changed. The number it
    /// changed comes from the command tag, never from counting rows, because counting stops at `countLimit`.
    func trial(_ sql: String) async throws -> DatabaseRows {
        try await Self.with(connection, within: 2 * DatabaseEngines.readTimeout + DatabaseTimes.slack) { conn in
            func attempt(_ statement: String) async throws -> DatabaseRows {
                try await Self.run(conn, "BEGIN")
                try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'")
                let result = try await Self.command(conn, statement)
                try await Self.run(conn, "ROLLBACK")
                return result
            }
            if let returning = SQLText.returning(sql) {
                // RETURNING may not fit the statement (a view, a rule). Then its transaction is ended and the
                // statement is tried plain
                do { return try await attempt(returning) } catch let first {
                    do { try await Self.run(conn, "ROLLBACK") } catch {
                        throw first   // the connection is gone, so report the first try's error, not the ROLLBACK's
                    }
                }
            }
            return try await attempt(sql)
        }
    }

    /// Makes a change. `allowed` is the number of rows the user allowed it to change, and the change is committed
    /// only if it changes that many.
    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows {
        try await Self.with(connection, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            guard let allowed else {
                try await Self.run(conn, "SET statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
                return try await Self.command(conn, sql)
            }
            try await Self.run(conn, "BEGIN")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            let result = try await Self.command(conn, sql)
            guard result.changed == allowed else {
                // A ROLLBACK that fails (the connection is gone) rolls back all the same, so the error gives the count
                await DatabaseWire.close { try await Self.run(conn, "ROLLBACK") }
                throw DatabaseEngines.notAsAllowed(result.changed, allowed)
            }
            try await Self.run(conn, "COMMIT")
            return result
        }
    }

    /// Runs the statements in one transaction. A failure leaves nothing done, because the connection closes without
    /// COMMIT.
    func apply(_ statements: [String]) async throws -> Int {
        try await Self.with(connection, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            try await Self.run(conn, "BEGIN")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            var changed = 0
            for sql in statements { changed += try await Self.command(conn, sql).changed ?? 0 }
            try await Self.run(conn, "COMMIT")
            return changed
        }
    }

    func batch(_ statements: [String], keep: @escaping @Sendable ([Int?]) -> Bool) async throws -> [Int?] {
        try await Self.with(connection, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            try await Self.run(conn, "BEGIN")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            var changed: [Int?] = []
            for sql in statements { changed.append(try await Self.command(conn, sql).changed) }
            guard keep(changed) else {
                await DatabaseWire.close { try await Self.run(conn, "ROLLBACK") }
                return changed
            }
            try await Self.run(conn, "COMMIT")
            return changed
        }
    }

    func schema() async throws -> DatabaseSchema {
        try await Self.with(connection) { conn in
            try await Self.run(conn, "BEGIN TRANSACTION READ ONLY")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'")
            let columns = try await Self.rows(conn, PostgresRun.schemaColumns)
            let counts = try await Self.rows(conn, PostgresRun.schemaCounts)
            let indexes = try await Self.rows(conn, PostgresRun.schemaIndexes)
            var schema = DatabaseSchemaBuilder.build(columns: columns.rows, counts: counts.rows, indexes: indexes.rows)
            schema.functions = try await Self.rows(conn, PostgresRun.schemaFunctions).rows.compactMap {
                $0.first ?? nil
            }
            return schema
        }
    }

    /// The databases on the server, for the sheet's pop-up menu.
    func databases() async throws -> [String] {
        try await Self.with(connection) { conn in
            try await Self.rows(
                conn, "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname"
            ).rows.compactMap { $0.first ?? nil }
        }
    }

    /// Returns "PostgreSQL 16.4" or the like, for the check in the Add Database sheet.
    func version() async throws -> String? {
        try await Self.with(connection) { conn in
            let full = try await Self.rows(conn, "SELECT version()").rows.first?.first ?? nil
            return full?.split(separator: " ").prefix(2).joined(separator: " ") ?? "Postgres"
        }
    }

    /// Opens a connection, runs `body` on it and closes it. `seconds` limits the call's whole time
    /// (`DatabaseWire.within`).
    private static func with<T: Sendable>(
        _ databaseConnection: DatabaseConnection,
        within seconds: TimeInterval = DatabaseEngines.readTimeout + DatabaseTimes.slack,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        let db = databaseConnection.database, config = try configuration(databaseConnection)
        let conn: PostgresConnection
        do {
            conn = try await PostgresConnection.connect(
                on: DatabaseWire.eventLoop, configuration: config, id: 1, logger: DatabaseWire.logger
            ).get()
        } catch { throw failure(error, db) }
        do {
            let result = try await DatabaseWire.within(
                seconds, db, close: { await DatabaseWire.close { try await conn.close() } }
            ) { try await body(conn) }
            await DatabaseWire.close { try await conn.close() }
            return result
        } catch {
            await DatabaseWire.close { try await conn.close() }   // a transaction left open ends with the connection
            throw failure(error, db)
        }
    }

    /// The connection's settings: TLS as the sslmode says, checked against the server's own name when it is reached
    /// through a forwarded port.
    static func configuration(_ databaseConnection: DatabaseConnection) throws -> PostgresConnection.Configuration {
        let db = databaseConnection.database
        guard let host = db.host else { throw DatabaseFailure.failed("\(db.name) has no address to reach it at.") }
        let user = db.user ?? NSUserName(), port = db.port ?? db.engine.defaultPort ?? 0
        let password =
            databaseConnection.password
            ?? (PgPass.mayUse(for: db, host: host)
                ? PgPass.password(host: host, port: port, database: db.database, user: user) : nil)
        let context = try NIOSSLContext(configuration: DatabaseWire.tls(db, name: databaseConnection.serverName))
        var config = PostgresConnection.Configuration(
            host: host, port: port, username: user, password: password, database: db.database,
            tls: db.ssl == "disable" ? .disable : DatabaseWire.requiresTLS(db) ? .require(context) : .prefer(context))
        config.options.tlsServerName = databaseConnection.serverName
        config.options.connectTimeout = .seconds(Int64(DatabaseTimes.connect))
        // Use UTC, as `PostgresText` writes timestamptz, so a row found by its values (`::text`) compares the same
        config.options.additionalStartupParameters = [("application_name", "kelp"), ("TimeZone", "UTC")]
        return config
    }

    private static func run(_ conn: PostgresConnection, _ sql: String) async throws {
        _ = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: DatabaseWire.logger).collect()
    }

    /// Returns the rows as text, with the columns even when there are no rows. Up to `keep` rows are kept, and rows
    /// are counted up to `countLimit`.
    static func rows(_ conn: PostgresConnection, _ sql: String) async throws -> DatabaseRows {
        let sequence = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: DatabaseWire.logger)
        var texts = PostgresTexts(rows: DatabaseRows(columns: sequence.columns.map(\.name)))
        for try await row in sequence {
            texts.add(Array(row))
            if texts.rows.total >= DatabaseEngines.countLimit { break }
        }
        return try await texts.finish(on: conn)
    }

    /// Runs a statement whose command tag says how many rows it changed ("UPDATE 3"), with whatever rows it returned.
    /// Up to `keep` rows are kept as they come, and the rest are only counted.
    static func command(_ conn: PostgresConnection, _ sql: String) async throws -> DatabaseRows {
        let kept = OSAllocatedUnfairLock(initialState: PostgresTexts())
        let metadata = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: DatabaseWire.logger) { row in
            kept.withLock { $0.add(Array(row)) }
        }.get()
        var texts = kept.withLock { $0 }
        var result = try await texts.finish(on: conn)
        result.changed = metadata.rows ?? (["SELECT", "SHOW"].contains(metadata.command) ? nil : 0)
        return result
    }

    /// Turns an error into a failure in the server's own words. A change refused by a read-only transaction becomes
    /// `.change`.
    static func failure(_ error: any Error, _ db: DatabaseInfo) -> any Error {
        if error is DatabaseFailure { return error }
        if let unreached = DatabaseWire.unreached(error, db) { return unreached }
        if let uncertified = DatabaseWire.uncertified(error, db) { return uncertified }
        guard let psql = error as? PSQLError else { return DatabaseFailure.failed("\(error)") }
        if let info = psql.serverInfo {
            if info[.sqlState] == "25006" { return DatabaseFailure.change }
            let message = info[.message] ?? "the server refused it"
            // This is the server's message for a login with no password (Kelp sends none when it has none)
            if message.contains("empty password") { return DatabaseWire.noPassword(db) }
            return DatabaseFailure.failed(message + (info[.hint].map { " (\($0))" } ?? ""))
        }
        switch psql.code {
        case .authMechanismRequiresPassword: return DatabaseWire.noPassword(db)
        case .sslUnsupported: return DatabaseFailure.failed("\(db.name) doesn't offer SSL, and it's required.")
        case .queryCancelled: return DatabaseFailure.failed("\(db.name) cancelled it.")
        case .serverClosedConnection where psql.underlying == nil, .connectionError where psql.underlying == nil:
            // PostgresNIO reports this for a connection that never got an answer (its connect timed out)
            return DatabaseFailure.failed(
                "\(db.name) didn't answer at \(db.host ?? "?"):\(db.port ?? db.engine.defaultPort ?? 0): it's off, "
                    + "or a VPN or SSH is needed."
            )
        default:
            let said = psql.underlying.map { "\($0)" } ?? "\(psql.code)"
            // NIO says "connect(descriptor:addr:size:): Connection refused (errno: 61)"; report only the reason, as
            // psql does
            if said.contains("Connection refused") { return DatabaseFailure.failed("Connection refused") }
            if said.contains("timed out") || said.contains("connectTimeout") {
                return DatabaseFailure.failed(
                    "\(db.name) didn't answer at \(db.address) in \(Int(DatabaseTimes.connect)) s.")
            }
            return DatabaseFailure.failed(said)
        }
    }
}
