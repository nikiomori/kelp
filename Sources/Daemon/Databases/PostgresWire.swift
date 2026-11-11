import Core
import Foundation
import NIOSSL
import PostgresNIO
import os

// Postgres spoken by kelpd itself (PostgresNIO): reads, writes, schema, over one connection a call.

struct PostgresWire: DatabaseRunner {
    let c: DatabaseConnection

    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        try await Self.with(c, within: timeout + 10) { conn in
            try await Self.run(conn, "BEGIN TRANSACTION READ ONLY")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(timeout))s'")
            return try await Self.rows(conn, sql)
        }
    }

    /// The change made and rolled back; with RETURNING its rows are what it changed. How many it changed is the
    /// command tag's, never the rows counted (they stop at `countLimit`).
    func trial(_ sql: String) async throws -> DatabaseRows {
        try await Self.with(c, within: 2 * DatabaseEngines.readTimeout + DatabaseTimes.slack) { conn in
            func attempt(_ statement: String) async throws -> DatabaseRows {
                try await Self.run(conn, "BEGIN")
                try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'")
                let result = try await Self.command(conn, statement)
                try await Self.run(conn, "ROLLBACK")
                return result
            }
            if let returning = SQLText.returning(sql) {
                // RETURNING may not fit it (a view, a rule): tried plain then, its transaction ended first
                do { return try await attempt(returning) } catch let first {
                    do { try await Self.run(conn, "ROLLBACK") } catch {
                        throw first   // the connection is gone: the server's word on the first, not the ROLLBACK's
                    }
                }
            }
            return try await attempt(sql)
        }
    }

    /// `allowed`: the rows the user allowed it to change; it's committed only if it changes as many.
    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows {
        try await Self.with(c, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            guard let allowed else {
                try await Self.run(conn, "SET statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
                return try await Self.command(conn, sql)
            }
            try await Self.run(conn, "BEGIN")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            let result = try await Self.command(conn, sql)
            guard result.changed == allowed else {
                // A ROLLBACK that fails (the connection gone) rolls back all the same: the count is what's said
                await DatabaseWire.close { try await Self.run(conn, "ROLLBACK") }
                throw DatabaseEngines.notAsAllowed(result.changed, allowed)
            }
            try await Self.run(conn, "COMMIT")
            return result
        }
    }

    /// Statements in one transaction: a failure leaves nothing done (the connection closes without COMMIT).
    func apply(_ statements: [String]) async throws -> Int {
        try await Self.with(c, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            try await Self.run(conn, "BEGIN")
            try await Self.run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            var changed = 0
            for sql in statements { changed += try await Self.command(conn, sql).changed ?? 0 }
            try await Self.run(conn, "COMMIT")
            return changed
        }
    }

    func schema() async throws -> DatabaseSchema {
        try await Self.with(c) { conn in
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

    /// The server's databases, for the sheet's pop-up.
    func databases() async throws -> [String] {
        try await Self.with(c) { conn in
            try await Self.rows(
                conn, "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname"
            ).rows.compactMap { $0.first ?? nil }
        }
    }

    /// "PostgreSQL 16.4" and the like, for the sheet's check.
    func version() async throws -> String? {
        try await Self.with(c) { conn in
            let full = try await Self.rows(conn, "SELECT version()").rows.first?.first ?? nil
            return full?.split(separator: " ").prefix(2).joined(separator: " ") ?? "Postgres"
        }
    }

    /// `seconds`: the call's whole time (`DatabaseWire.within`).
    private static func with<T: Sendable>(
        _ c: DatabaseConnection, within seconds: TimeInterval = DatabaseEngines.readTimeout + DatabaseTimes.slack,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        let db = c.database
        guard let host = db.host else { throw DatabaseFailure.failed("\(db.name) has no address to reach it at.") }
        let user = db.user ?? NSUserName(), port = db.port ?? db.engine.defaultPort ?? 0
        let password =
            c.password
            ?? (PgPass.mayUse(for: db, host: host)
                ? PgPass.password(host: host, port: port, database: db.database, user: user) : nil)
        let context = try NIOSSLContext(configuration: DatabaseWire.tls)
        var config = PostgresConnection.Configuration(
            host: host, port: port, username: user, password: password, database: db.database,
            tls: db.ssl == "disable" ? .disable : db.ssl == "require" ? .require(context) : .prefer(context))
        config.options.connectTimeout = .seconds(Int64(DatabaseTimes.connect))
        // UTC: timestamptz as `PostgresText` writes it, so a row found by its values (`::text`) compares the same
        config.options.additionalStartupParameters = [("application_name", "kelp"), ("TimeZone", "UTC")]
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
            await DatabaseWire.close { try await conn.close() }   // a transaction left open ends with it
            throw failure(error, db)
        }
    }

    private static func run(_ conn: PostgresConnection, _ sql: String) async throws {
        _ = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: DatabaseWire.logger).collect()
    }

    /// Rows as text, the columns even when there are none; up to `keep` kept, counted up to `countLimit`.
    static func rows(_ conn: PostgresConnection, _ sql: String) async throws -> DatabaseRows {
        let sequence = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: DatabaseWire.logger)
        var result = DatabaseRows(columns: sequence.columns.map(\.name))
        for try await row in sequence {
            result.add(row.map(PostgresText.text))
            if result.total >= DatabaseEngines.countLimit { break }
        }
        return result
    }

    /// A statement whose command tag says how many rows it changed ("UPDATE 3"), with whatever rows it gave: `keep`
    /// kept as they come, the rest only counted.
    static func command(_ conn: PostgresConnection, _ sql: String) async throws -> DatabaseRows {
        let kept = OSAllocatedUnfairLock(initialState: DatabaseRows())
        let metadata = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: DatabaseWire.logger) { row in
            let names = row.map(\.columnName), values = row.map(PostgresText.text)
            kept.withLock { $0.add(columns: names, values) }
        }.get()
        var result = kept.withLock { $0 }
        result.changed = metadata.rows ?? (["SELECT", "SHOW"].contains(metadata.command) ? nil : 0)
        return result
    }

    /// The server's own words; a change refused by a read-only transaction is `.change`.
    static func failure(_ error: any Error, _ db: DatabaseInfo) -> any Error {
        if error is DatabaseFailure { return error }
        if let unreached = DatabaseWire.unreached(error, db) { return unreached }
        guard let psql = error as? PSQLError else { return DatabaseFailure.failed("\(error)") }
        if let info = psql.serverInfo {
            if info[.sqlState] == "25006" { return DatabaseFailure.change }
            let message = info[.message] ?? "the server refused it"
            // The server's word for a login with no password (Kelp sends none when it has none)
            if message.contains("empty password") { return DatabaseWire.noPassword(db) }
            return DatabaseFailure.failed(message + (info[.hint].map { " (\($0))" } ?? ""))
        }
        switch psql.code {
        case .authMechanismRequiresPassword: return DatabaseWire.noPassword(db)
        case .sslUnsupported: return DatabaseFailure.failed("\(db.name) doesn't offer SSL, and it's required.")
        case .queryCancelled: return DatabaseFailure.failed("\(db.name) cancelled it.")
        case .serverClosedConnection where psql.underlying == nil, .connectionError where psql.underlying == nil:
            // PostgresNIO's word for a connection that never got an answer (its connect timed out)
            return DatabaseFailure.failed(
                "\(db.name) didn't answer at \(db.host ?? "?"):\(db.port ?? db.engine.defaultPort ?? 0): it's off, "
                    + "or a VPN or SSH is needed."
            )
        default:
            let said = psql.underlying.map { "\($0)" } ?? "\(psql.code)"
            // NIO's "connect(descriptor:addr:size:): Connection refused (errno: 61)": the reason, as psql says it
            if said.contains("Connection refused") { return DatabaseFailure.failed("Connection refused") }
            if said.contains("timed out") || said.contains("connectTimeout") {
                return DatabaseFailure.failed(
                    "\(db.name) didn't answer at \(db.address) in \(Int(DatabaseTimes.connect)) s.")
            }
            return DatabaseFailure.failed(said)
        }
    }
}
