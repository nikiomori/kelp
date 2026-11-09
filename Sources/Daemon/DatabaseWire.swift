import Core
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO
import os

/// Postgres and MySQL spoken by kelpd itself, at an address it reaches (the database's own, or a forwarded port): no
/// psql or mysql on the Mac. One connection a call, closed after it. Reads run in a read-only transaction, so the
/// server refuses a change (`DatabaseFailure.change`); TLS is used when the server offers it, its certificate not
/// checked (as psql's default `sslmode=prefer` does).
enum DatabaseWire {
    static let logger: Logger = {
        var logger = Logger(label: "kelp.db")
        logger.logLevel = .critical
        return logger
    }()

    /// TLS that takes what the server shows: the connection is to a server the user named.
    static let tls: TLSConfiguration = {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = .none
        return config
    }()

    static var eventLoop: any EventLoop { MultiThreadedEventLoopGroup.singleton.any() }

    /// A login refused for want of a password: where to give one.
    static func noPassword(_ db: DatabaseInfo) -> DatabaseFailure {
        .failed("Kelp has no password for \(db.name): Edit… to type one, or import it again.")
    }

    /// A host the network doesn't know (a VPN's, a cluster's inside name): said as such, not as NIO's error.
    static func unreached(_ error: any Error, _ db: DatabaseInfo) -> DatabaseFailure? {
        let said = "\(error)" + ((error as? PSQLError)?.underlying.map { " \($0)" } ?? "")
        guard said.contains("UnknownHost") || said.contains("nodename nor servname") else { return nil }
        return .failed("Can't find \(db.host ?? db.name) on the network: is a VPN or SSH needed to reach it?")
    }

    /// The call's whole time, past what the server's own limit stops: a network gone mid-read (a VPN dropped, the Mac
    /// asleep) answers nothing, so past it the connection is closed, which ends what waits on it.
    static func within<T: Sendable>(
        _ seconds: TimeInterval, _ db: DatabaseInfo, close: @escaping @Sendable () async -> Void,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: WireOutcome<T>.self) { group in
            group.addTask { .done(try await body()) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return .late
            }
            defer { group.cancelAll() }
            if case .done(let result) = try await group.next() { return result }
            await close()
            throw DatabaseFailure.failed("No answer from \(db.name) in \(Int(seconds)) s.")
        }
    }

    /// What `future` gives, or a failure once `seconds` have passed (then `late`): for a step whose future can't be
    /// cancelled or closed (a handshake), which `within` would wait out.
    static func first<T: Sendable>(
        _ future: EventLoopFuture<T>, within seconds: TimeInterval, _ db: DatabaseInfo,
        late: @escaping @Sendable () -> Void
    ) async throws -> T {
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
        /// Whether it was the first to answer.
        @Sendable func give(_ result: Result<T, any Error>) -> Bool {
            let continuation = waiting.withLock { held in
                defer { held = nil }
                return held
            }
            continuation?.resume(with: result)
            return continuation != nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.withLock { $0 = continuation }
            let timer = future.eventLoop.scheduleTask(in: .milliseconds(Int64(seconds * 1000))) {
                let said = "No answer from \(db.name) in \(Int(seconds.rounded(.up))) s."
                if give(.failure(DatabaseFailure.failed(said))) { late() }
            }
            future.whenComplete { result in
                timer.cancel()
                _ = give(result)
            }
        }
    }

    /// A connection closed after its call: one the server dropped already has nothing more to say.
    static func close(_ body: () async throws -> Void) async {
        do { try await body() } catch { logger.debug("db close: \(error)") }
    }
}

/// The call's answer, or its time ran out first (`DatabaseWire.within`).
private enum WireOutcome<T: Sendable>: Sendable {
    case done(T)
    case late
}

// MARK: Postgres

enum PostgresWire {
    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        try await with(c, within: timeout + 10) { conn in
            try await run(conn, "BEGIN TRANSACTION READ ONLY")
            try await run(conn, "SET LOCAL statement_timeout = '\(Int(timeout))s'")
            return try await rows(conn, sql)
        }
    }

    /// The change made and rolled back; with RETURNING its rows are what it changed. How many it changed is the
    /// command tag's, never the rows counted (they stop at `countLimit`).
    static func trial(_ c: DatabaseConnection, _ sql: String) async throws -> DatabaseRows {
        try await with(c, within: 2 * DatabaseEngines.readTimeout + 10) { conn in
            func attempt(_ statement: String) async throws -> DatabaseRows {
                try await run(conn, "BEGIN")
                try await run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'")
                let result = try await command(conn, statement)
                try await run(conn, "ROLLBACK")
                return result
            }
            if let returning = SQLText.returning(sql) {
                // RETURNING may not fit it (a view, a rule): tried plain then, its transaction ended first
                do { return try await attempt(returning) } catch let first {
                    do { try await run(conn, "ROLLBACK") } catch {
                        throw first   // the connection is gone: the server's word on the first, not the ROLLBACK's
                    }
                }
            }
            return try await attempt(sql)
        }
    }

    /// `allowed`: the rows the user allowed it to change; it's committed only if it changes as many.
    static func write(_ c: DatabaseConnection, _ sql: String, allowed: Int? = nil) async throws -> DatabaseRows {
        try await with(c, within: DatabaseEngines.writeTimeout + 10) { conn in
            guard let allowed else {
                try await run(conn, "SET statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
                return try await command(conn, sql)
            }
            try await run(conn, "BEGIN")
            try await run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            let result = try await command(conn, sql)
            guard result.changed == allowed else {
                // A ROLLBACK that fails (the connection gone) rolls back all the same: the count is what's said
                await DatabaseWire.close { try await run(conn, "ROLLBACK") }
                throw DatabaseEngines.notAsAllowed(result.changed, allowed)
            }
            try await run(conn, "COMMIT")
            return result
        }
    }

    /// Statements in one transaction: a failure leaves nothing done (the connection closes without COMMIT).
    static func apply(_ c: DatabaseConnection, _ statements: [String]) async throws -> Int {
        try await with(c, within: DatabaseEngines.writeTimeout + 10) { conn in
            try await run(conn, "BEGIN")
            try await run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            var changed = 0
            for sql in statements { changed += try await command(conn, sql).changed ?? 0 }
            try await run(conn, "COMMIT")
            return changed
        }
    }

    static func schema(_ c: DatabaseConnection) async throws -> DatabaseSchema {
        try await with(c) { conn in
            try await run(conn, "BEGIN TRANSACTION READ ONLY")
            try await run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'")
            let columns = try await rows(conn, PostgresRun.schemaColumns)
            let counts = try await rows(conn, PostgresRun.schemaCounts)
            let indexes = try await rows(conn, PostgresRun.schemaIndexes)
            var schema = DatabaseSchemaBuilder.build(columns: columns.rows, counts: counts.rows, indexes: indexes.rows)
            schema.functions = try await rows(conn, PostgresRun.schemaFunctions).rows.compactMap { $0.first ?? nil }
            return schema
        }
    }

    /// The server's databases, for the sheet's pop-up.
    static func databases(_ c: DatabaseConnection) async throws -> [String] {
        try await with(c) { conn in
            try await rows(
                conn, "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname"
            ).rows.compactMap { $0.first ?? nil }
        }
    }

    /// "PostgreSQL 16.4" and the like, for the sheet's check.
    static func version(_ c: DatabaseConnection) async throws -> String {
        try await with(c) { conn in
            let full = try await rows(conn, "SELECT version()").rows.first?.first ?? nil
            return full?.split(separator: " ").prefix(2).joined(separator: " ") ?? "Postgres"
        }
    }

    /// `seconds`: the call's whole time (`DatabaseWire.within`).
    private static func with<T: Sendable>(
        _ c: DatabaseConnection, within seconds: TimeInterval = DatabaseEngines.readTimeout + 10,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        let db = c.database
        guard let host = db.host else { throw DatabaseFailure.failed("\(db.name) has no address to reach it at.") }
        let user = db.user ?? NSUserName()
        let password =
            c.password
            ?? (PgPass.mayUse(for: db, host: host)
                ? PgPass.password(host: host, port: db.port ?? 5432, database: db.database, user: user) : nil)
        let context = try NIOSSLContext(configuration: DatabaseWire.tls)
        var config = PostgresConnection.Configuration(
            host: host, port: db.port ?? 5432, username: user, password: password, database: db.database,
            tls: db.ssl == "disable" ? .disable : db.ssl == "require" ? .require(context) : .prefer(context))
        config.options.connectTimeout = .seconds(8)
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
                "\(db.name) didn't answer at \(db.host ?? "?"):\(db.port ?? 5432): it's off, or a VPN or SSH is needed."
            )
        default:
            let said = psql.underlying.map { "\($0)" } ?? "\(psql.code)"
            // NIO's "connect(descriptor:addr:size:): Connection refused (errno: 61)": the reason, as psql says it
            if said.contains("Connection refused") { return DatabaseFailure.failed("Connection refused") }
            if said.contains("timed out") || said.contains("connectTimeout") {
                return DatabaseFailure.failed("\(db.name) didn't answer at \(db.address) in 8 s.")
            }
            return DatabaseFailure.failed(said)
        }
    }
}
