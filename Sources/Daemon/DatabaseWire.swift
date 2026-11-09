import Core
import Foundation
import Logging
import MySQLNIO
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

    /// A connection closed after its call: one the server dropped already has nothing more to say.
    static func close(_ body: () async throws -> Void) async {
        do { try await body() } catch { logger.debug("db close: \(error)") }
    }
}

// MARK: Postgres

enum PostgresWire {
    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        try await with(c) { conn in
            try await run(conn, "BEGIN TRANSACTION READ ONLY")
            try await run(conn, "SET LOCAL statement_timeout = '\(Int(timeout))s'")
            return try await rows(conn, sql)
        }
    }

    /// The change made and rolled back; with RETURNING its rows are what it changed.
    static func trial(_ c: DatabaseConnection, _ sql: String) async throws -> DatabaseRows {
        try await with(c) { conn in
            func attempt(_ statement: String, returning: Bool) async throws -> DatabaseRows {
                try await run(conn, "BEGIN")
                try await run(conn, "SET LOCAL statement_timeout = '\(Int(DatabaseEngines.readTimeout))s'")
                var result = returning ? try await rows(conn, statement) : try await command(conn, statement)
                if returning { result.changed = result.total }
                try await run(conn, "ROLLBACK")
                return result
            }
            if let returning = SQLText.returning(sql) {
                // RETURNING may not fit it (a MERGE, a view): tried plain then
                do { return try await attempt(returning, returning: true) } catch DatabaseFailure.failed {}
            }
            return try await attempt(sql, returning: false)
        }
    }

    static func write(_ c: DatabaseConnection, _ sql: String) async throws -> DatabaseRows {
        try await with(c) { conn in
            try await run(conn, "SET statement_timeout = '\(Int(DatabaseEngines.writeTimeout))s'")
            return try await command(conn, sql)
        }
    }

    /// Statements in one transaction: a failure leaves nothing done (the connection closes without COMMIT).
    static func apply(_ c: DatabaseConnection, _ statements: [String]) async throws -> Int {
        try await with(c) { conn in
            try await run(conn, "BEGIN")
            var changed = 0
            for sql in statements { changed += try await command(conn, sql).changed ?? 0 }
            try await run(conn, "COMMIT")
            return changed
        }
    }

    static func schema(_ c: DatabaseConnection) async throws -> DatabaseSchema {
        try await with(c) { conn in
            try await run(conn, "BEGIN TRANSACTION READ ONLY")
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

    private static func with<T: Sendable>(
        _ c: DatabaseConnection, _ body: @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        let db = c.database
        guard let host = db.host else { throw DatabaseFailure.failed("\(db.name) has no address to reach it at.") }
        let user = db.user ?? NSUserName()
        let password =
            c.password ?? PgPass.password(host: host, port: db.port ?? 5432, database: db.database, user: user)
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
            let result = try await body(conn)
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
            result.total += 1
            if result.rows.count < DatabaseEngines.keep { result.rows.append(row.map(PostgresText.text)) }
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

// MARK: MySQL

/// MySQL and MariaDB over their text protocol: values come as the server writes them.
enum MySQLWire {
    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        try await with(c) { conn in
            try await limit(conn, timeout)
            _ = try await run(conn, "START TRANSACTION READ ONLY")
            return try await run(conn, sql)
        }
    }

    static func trial(_ c: DatabaseConnection, _ sql: String) async throws -> DatabaseRows {
        try await with(c) { conn in
            _ = try await run(conn, "START TRANSACTION")
            var result = try await run(conn, sql)
            result.changed = try await changed(conn)
            _ = try await run(conn, "ROLLBACK")
            return result
        }
    }

    static func write(_ c: DatabaseConnection, _ sql: String) async throws -> DatabaseRows {
        try await with(c) { conn in
            var result = try await run(conn, sql)
            result.changed = try await changed(conn)
            return result
        }
    }

    static func apply(_ c: DatabaseConnection, _ statements: [String]) async throws -> Int {
        try await with(c) { conn in
            _ = try await run(conn, "START TRANSACTION")
            var changed = 0
            for sql in statements {
                _ = try await run(conn, sql)
                changed += try await self.changed(conn) ?? 0
            }
            _ = try await run(conn, "COMMIT")
            return changed
        }
    }

    static func schema(_ c: DatabaseConnection) async throws -> DatabaseSchema {
        try await with(c) { conn in
            var schema = DatabaseSchemaBuilder.build(
                columns: try await run(conn, MySQLRun.schemaColumns).rows,
                counts: try await run(conn, MySQLRun.schemaCounts).rows,
                indexes: try await run(conn, MySQLRun.schemaIndexes).rows)
            schema.functions = try await run(conn, MySQLRun.schemaFunctions).rows.compactMap { $0.first ?? nil }
            return schema
        }
    }

    static func databases(_ c: DatabaseConnection) async throws -> [String] {
        try await with(c) { conn in
            try await run(conn, "SHOW DATABASES").rows.compactMap { $0.first ?? nil }.filter {
                !["information_schema", "performance_schema", "mysql", "sys"].contains($0)
            }
        }
    }

    static func version(_ c: DatabaseConnection) async throws -> String {
        try await with(c) { conn in
            let v = try await run(conn, "SELECT VERSION()").rows.first?.first ?? nil
            let number = v?.split(separator: "-").first.map(String.init) ?? ""
            return (v?.contains("MariaDB") == true ? "MariaDB " : "MySQL ") + number
        }
    }

    /// The server stops a read at `timeout`: MySQL calls it max_execution_time (ms), MariaDB max_statement_time (s),
    /// and each refuses the other's name.
    private static func limit(_ conn: MySQLConnection, _ timeout: TimeInterval) async throws {
        do { _ = try await run(conn, "SET SESSION max_execution_time = \(Int(timeout * 1000))") } catch {
            _ = try await run(conn, "SET SESSION max_statement_time = \(Int(timeout))")
        }
    }

    /// ROW_COUNT() right after the statement: anything between would reset it.
    private static func changed(_ conn: MySQLConnection) async throws -> Int? {
        (try await run(conn, "SELECT ROW_COUNT()").rows.first?.first ?? nil).flatMap(Int.init).map { max(0, $0) }
    }

    private static func with<T: Sendable>(
        _ c: DatabaseConnection, _ body: @Sendable (MySQLConnection) async throws -> T
    ) async throws -> T {
        let db = c.database
        guard let host = db.host else { throw DatabaseFailure.failed("\(db.name) has no address to reach it at.") }
        // localhost means the Unix socket to MySQL's own client: here it's the server's port, by address
        let address = host == "localhost" ? "127.0.0.1" : host
        let conn: MySQLConnection
        do {
            let port = db.port ?? 3306
            let socket = try await Slots.elsewhere { try SocketAddress.makeAddressResolvingHost(address, port: port) }
            conn = try await MySQLConnection.connect(
                to: socket, username: db.user ?? "root", database: db.database ?? "", password: c.password,
                tlsConfiguration: db.ssl == "disable" ? nil : DatabaseWire.tls, serverHostname: nil,
                logger: DatabaseWire.logger, on: DatabaseWire.eventLoop
            ).get()
        } catch { throw failure(error, db) }
        do {
            let result = try await body(conn)
            await DatabaseWire.close { try await conn.close().get() }
            return result
        } catch {
            await DatabaseWire.close { try await conn.close().get() }
            throw failure(error, db)
        }
    }

    /// One statement over the text protocol: its columns (when it gave rows) and rows, NULL as nil.
    /// Rows as they come: `keep` of them kept, the rest only counted (a SELECT * of millions doesn't fill kelpd).
    static func run(_ conn: MySQLConnection, _ sql: String) async throws -> DatabaseRows {
        let kept = OSAllocatedUnfairLock(initialState: DatabaseRows())
        try await conn.simpleQuery(sql) { row in
            let names = row.columnDefinitions.map(\.name), values = row.values.map { $0.map { String(buffer: $0) } }
            kept.withLock { $0.add(columns: names, values) }
        }.get()
        return kept.withLock { $0 }
    }

    static func failure(_ error: any Error, _ db: DatabaseInfo) -> any Error {
        if error is DatabaseFailure { return error }
        if let unreached = DatabaseWire.unreached(error, db) { return unreached }
        let said = "\(error)"
        if said.contains("using password: NO") { return DatabaseWire.noPassword(db) }
        if said.contains("READ ONLY transaction") { return DatabaseFailure.change }
        if said.contains("Connection refused") { return DatabaseFailure.failed("Can't connect: Connection refused") }
        if let error = error as? MySQLError {
            return DatabaseFailure.failed(error.message)
        }
        return DatabaseFailure.failed(said)
    }
}

extension MySQLError {
    /// The server's words without the protocol's wrapping.
    var message: String {
        switch self {
        case .server(let packet): packet.errorMessage
        default: "\(self)"
        }
    }
}
