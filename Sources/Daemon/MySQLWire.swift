import Core
import Foundation
import MySQLNIO
import NIOCore
import os

// MySQL and MariaDB spoken by kelpd itself (MySQLNIO): reads, writes, schema, and a query's own time.

/// MySQL and MariaDB over their text protocol: values come as the server writes them.
enum MySQLWire {
    static func read(_ c: DatabaseConnection, _ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        try await with(c, within: timeout + 10) { conn in
            try await limit(conn, timeout)
            _ = try await run(conn, "START TRANSACTION READ ONLY")
            return try await run(conn, sql)
        }
    }

    static func trial(_ c: DatabaseConnection, _ sql: String) async throws -> DatabaseRows {
        try await with(c, within: 60) { conn in
            let tables = try await run(conn, MySQLRun.unrollable).rows.first?.first ?? nil
            guard tables == "0" else { throw MySQLRun.cantRollBack }
            _ = try await run(conn, "START TRANSACTION")
            var result = try await run(conn, sql)
            result.changed = try await changed(conn)
            _ = try await run(conn, "ROLLBACK")
            return result
        }
    }

    /// `allowed`: as Postgres' (a row change only: MySQL's DDL isn't tried, so it has no count to hold it to).
    static func write(_ c: DatabaseConnection, _ sql: String, allowed: Int? = nil) async throws -> DatabaseRows {
        try await with(c, within: DatabaseEngines.writeTimeout + 10) { conn in
            if allowed != nil { _ = try await run(conn, "START TRANSACTION") }
            var result = try await run(conn, sql)
            result.changed = try await changed(conn)
            guard let allowed else { return result }
            guard result.changed == allowed else {
                // A ROLLBACK that fails (the connection gone) rolls back all the same: the count is what's said
                await DatabaseWire.close { _ = try await run(conn, "ROLLBACK") }
                throw DatabaseEngines.notAsAllowed(result.changed, allowed)
            }
            _ = try await run(conn, "COMMIT")
            return result
        }
    }

    static func apply(_ c: DatabaseConnection, _ statements: [String]) async throws -> Int {
        try await with(c, within: DatabaseEngines.writeTimeout + 10) { conn in
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
            let banner = try await run(conn, "SELECT VERSION()").rows.first?.first ?? nil
            let number = banner?.split(separator: "-").first.map(String.init) ?? ""
            return (banner?.contains("MariaDB") == true ? "MariaDB " : "MySQL ") + number
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

    /// `seconds`: the call's whole time (`DatabaseWire.within`).
    /// The call on a connection of its own. The handshake has its own time (NIO's 10 s is the TCP connect's only); a
    /// call past its time is stopped on the server too (`KILL QUERY` from a second connection), since MySQL's own
    /// limit stops only a SELECT: a change that ran on would commit after the caller was told it didn't answer.
    private static func with<T: Sendable>(
        _ c: DatabaseConnection, within seconds: TimeInterval = DatabaseEngines.readTimeout + 10,
        _ body: @escaping @Sendable (MySQLConnection) async throws -> T
    ) async throws -> T {
        let db = c.database
        let conn: MySQLConnection
        do { conn = try await open(c) } catch { throw failure(error, db) }
        // The connection's id, asked first inside the call's time: what a second connection stops when it runs out
        let id = OSAllocatedUnfairLock<String?>(initialState: nil)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        do {
            let result = try await DatabaseWire.within(
                seconds, db,
                close: {
                    await DatabaseWire.close { try await conn.close().get() }
                    let killed = await kill(id.withLock { $0 }, c)
                    stopped.withLock { $0 = killed }
                }
            ) {
                let asked = try await run(conn, "SELECT CONNECTION_ID()").rows.first?.first ?? nil
                id.withLock { $0 = asked }
                return try await body(conn)
            }
            await DatabaseWire.close { try await conn.close().get() }
            return result
        } catch DatabaseFailure.failed(let said) where said.hasPrefix("No answer from") {
            await DatabaseWire.close { try await conn.close().get() }
            throw DatabaseFailure.failed(
                said
                    + (stopped.withLock { $0 }
                        ? " Kelp stopped it on the server."
                        : " It may still be running on the server: look before running it again."))
        } catch {
            await DatabaseWire.close { try await conn.close().get() }
            throw failure(error, db)
        }
    }

    static let handshakeTimeout: TimeInterval = 10
    /// A KILL QUERY's handshake, and then its answer: what a call past its time adds to it, at most twice this.
    static let killTimeout: TimeInterval = 3

    static func open(_ c: DatabaseConnection, handshake: TimeInterval = handshakeTimeout) async throws
        -> MySQLConnection
    {
        let db = c.database
        guard let host = db.host else { throw DatabaseFailure.failed("\(db.name) has no address to reach it at.") }
        // localhost means the Unix socket to MySQL's own client: here it's the server's port, by address
        let address = host == "localhost" ? "127.0.0.1" : host
        let port = db.port ?? 3306
        let socket = try await Slots.elsewhere { try SocketAddress.makeAddressResolvingHost(address, port: port) }
        let connecting = MySQLConnection.connect(
            to: socket, username: db.user ?? "root", database: db.database ?? "", password: c.password,
            tlsConfiguration: db.ssl == "disable" ? nil : DatabaseWire.tls, serverHostname: nil,
            logger: DatabaseWire.logger, on: DatabaseWire.eventLoop
        )
        // Limit: MySQLNIO doesn't hand out the channel before the handshake ends, so one that never does keeps its
        // socket until the far end closes it; one that ends late is closed then.
        return try await DatabaseWire.first(connecting, within: handshake, db) {
            connecting.whenSuccess { late in _ = late.close() }
        }
    }

    /// Stops what connection `id` runs, from a connection of its own: whether the server said it did.
    private static func kill(_ id: String?, _ c: DatabaseConnection) async -> Bool {
        guard let id, Int(id) != nil else { return false }
        do {
            let conn = try await open(c, handshake: killTimeout)
            var said: (any Error)?
            // A server that didn't answer the call may not answer this either: it has a time of its own
            do {
                _ = try await DatabaseWire.within(
                    killTimeout, c.database, close: { await DatabaseWire.close { try await conn.close().get() } }
                ) { try await run(conn, "KILL QUERY \(id)") }
            } catch { said = error }
            await DatabaseWire.close { try await conn.close().get() }
            if let said { throw said }
            return true
        } catch {
            Log.session.info("db: KILL QUERY on \(c.database.name) failed: \(error)")
            return false
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
