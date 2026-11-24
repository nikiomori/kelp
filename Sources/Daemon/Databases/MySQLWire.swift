import Core
import Foundation
import MySQLNIO
import NIOCore
import os

// Reads, writes and schema for MySQL and MariaDB, spoken by kelpd itself (MySQLNIO), with a time limit on each query.

/// Talks to MySQL and MariaDB over their text protocol, so values come as the server writes them.
struct MySQLWire: DatabaseRunner {
    let connection: DatabaseConnection
    /// How long a read may run past the server's own limit before its connection is closed.
    var grace: TimeInterval = 10
    /// How long logging in may take, before the call's own time starts.
    var handshake: TimeInterval = DatabaseTimes.handshake

    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        try await Self.with(connection, within: timeout + grace, handshake: handshake) { conn in
            try await Self.limit(conn, timeout)
            _ = try await Self.run(conn, "START TRANSACTION READ ONLY")
            return try await Self.run(conn, sql)
        }
    }

    func trial(_ sql: String) async throws -> DatabaseRows {
        try await Self.with(connection, within: DatabaseTimes.trial) { conn in
            let tables = try await Self.run(conn, MySQLRun.unrollable).rows.first?.first ?? nil
            guard tables == "0" else { throw MySQLRun.cantRollBack }
            _ = try await Self.run(conn, "START TRANSACTION")
            var result = try await Self.run(conn, sql)
            result.changed = try await Self.changed(conn)
            _ = try await Self.run(conn, "ROLLBACK")
            return result
        }
    }

    /// Handles `allowed` as the Postgres runner does. That holds for a row change only, because MySQL's DDL isn't
    /// tried and so has no count to hold it to.
    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows {
        try await Self.with(connection, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            if allowed != nil { _ = try await Self.run(conn, "START TRANSACTION") }
            var result = try await Self.run(conn, sql)
            result.changed = try await Self.changed(conn)
            guard let allowed else { return result }
            guard result.changed == allowed else {
                // A ROLLBACK that fails (the connection is gone) rolls back all the same, so the error gives the count
                await DatabaseWire.close { _ = try await Self.run(conn, "ROLLBACK") }
                throw DatabaseEngines.notAsAllowed(result.changed, allowed)
            }
            _ = try await Self.run(conn, "COMMIT")
            return result
        }
    }

    func apply(_ statements: [String]) async throws -> Int {
        try await Self.with(connection, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            _ = try await Self.run(conn, "START TRANSACTION")
            var changed = 0
            for sql in statements {
                _ = try await Self.run(conn, sql)
                changed += try await Self.changed(conn) ?? 0
            }
            _ = try await Self.run(conn, "COMMIT")
            return changed
        }
    }

    /// Refuses when some table can't roll back (`MySQLRun.unrollable`), because then Kelp couldn't keep all of the
    /// statements or none.
    func batch(_ statements: [String], keep: @escaping @Sendable ([Int?]) -> Bool) async throws -> [Int?] {
        try await Self.with(connection, within: DatabaseEngines.writeTimeout + DatabaseTimes.slack) { conn in
            let tables = try await Self.run(conn, MySQLRun.unrollable).rows.first?.first ?? nil
            guard tables == "0" else { throw MySQLRun.cantRollBack }
            _ = try await Self.run(conn, "START TRANSACTION")
            var changed: [Int?] = []
            for sql in statements {
                _ = try await Self.run(conn, sql)
                changed.append(try await Self.changed(conn))
            }
            _ = try await Self.run(conn, keep(changed) ? "COMMIT" : "ROLLBACK")
            return changed
        }
    }

    func schema() async throws -> DatabaseSchema {
        try await Self.with(connection) { conn in
            var schema = DatabaseSchemaBuilder.build(
                columns: try await Self.run(conn, MySQLRun.schemaColumns).rows,
                counts: try await Self.run(conn, MySQLRun.schemaCounts).rows,
                indexes: try await Self.run(conn, MySQLRun.schemaIndexes).rows)
            schema.functions = try await Self.run(conn, MySQLRun.schemaFunctions).rows.compactMap { $0.first ?? nil }
            return schema
        }
    }

    func databases() async throws -> [String] {
        try await Self.with(connection) { conn in
            try await Self.run(conn, "SHOW DATABASES").rows.compactMap { $0.first ?? nil }.filter {
                !["information_schema", "performance_schema", "mysql", "sys"].contains($0)
            }
        }
    }

    func version() async throws -> String? {
        try await Self.with(connection) { conn in
            let banner = try await Self.run(conn, "SELECT VERSION()").rows.first?.first ?? nil
            let number = banner?.split(separator: "-").first.map(String.init) ?? ""
            return (banner?.contains("MariaDB") == true ? "MariaDB " : "MySQL ") + number
        }
    }

    /// Tells the server to stop a read at `timeout`. MySQL calls the setting max_execution_time (in ms) and MariaDB
    /// max_statement_time (in s), and each refuses the other's name.
    private static func limit(_ conn: MySQLConnection, _ timeout: TimeInterval) async throws {
        do { _ = try await run(conn, "SET SESSION max_execution_time = \(Int(timeout * 1000))") } catch {
            _ = try await run(conn, "SET SESSION max_statement_time = \(Int(timeout))")
        }
    }

    /// Reads ROW_COUNT(), which must come right after the statement because anything in between would reset it.
    private static func changed(_ conn: MySQLConnection) async throws -> Int? {
        (try await run(conn, "SELECT ROW_COUNT()").rows.first?.first ?? nil).flatMap(Int.init).map { max(0, $0) }
    }

    /// Runs the call on a connection of its own. `seconds` limits the call's whole time (`DatabaseWire.within`).
    /// The handshake has its own time limit, because NIO's 10 s covers only the TCP connect. A call past its time is
    /// stopped on the server too (`KILL QUERY` from a second connection), because MySQL's own limit stops only a
    /// SELECT. Otherwise a change that ran on would commit after the caller was told it didn't answer.
    private static func with<T: Sendable>(
        _ databaseConnection: DatabaseConnection,
        within seconds: TimeInterval = DatabaseEngines.readTimeout + DatabaseTimes.slack,
        handshake: TimeInterval = handshakeTimeout,
        _ body: @escaping @Sendable (MySQLConnection) async throws -> T
    ) async throws -> T {
        let db = databaseConnection.database
        let conn: MySQLConnection
        do { conn = try await open(databaseConnection, handshake: handshake) } catch { throw failure(error, db) }
        // The connection's id is asked first, inside the call's time, so a second connection can stop this one when
        // the time runs out
        let id = OSAllocatedUnfairLock<String?>(initialState: nil)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        do {
            let result = try await DatabaseWire.within(
                seconds, db,
                close: {
                    await DatabaseWire.close { try await conn.close().get() }
                    let killed = await kill(id.withLock { $0 }, databaseConnection)
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
            throw DatabaseFailure.failed(late(said, stopped: stopped.withLock { $0 }))
        } catch {
            await DatabaseWire.close { try await conn.close().get() }
            throw failure(error, db)
        }
    }

    /// Returns the message for a call past its time, worded so that nobody reruns a change that may have run. KILL
    /// QUERY stops a statement that still runs, but one that had just finished (and committed, outside a transaction)
    /// stays done.
    static func late(_ said: String, stopped: Bool) -> String {
        said
            + (stopped
                ? " Kelp stopped it on the server, unless it had finished by then: look before running it again."
                : " It may still be running on the server: look before running it again.")
    }

    static let handshakeTimeout = DatabaseTimes.handshake
    /// The time limit for a KILL QUERY's handshake, and then for its answer. So a call past its time takes at most
    /// twice this longer.
    static let killTimeout = DatabaseTimes.kill

    static func open(_ databaseConnection: DatabaseConnection, handshake: TimeInterval = handshakeTimeout) async throws
        -> MySQLConnection
    {
        let db = databaseConnection.database
        guard let host = db.host else { throw DatabaseFailure.failed("\(db.name) has no address to reach it at.") }
        // For MySQL's own client, localhost means the Unix socket; here it means the server's port, reached by address
        let address = host == "localhost" ? "127.0.0.1" : host
        let port = db.port ?? db.engine.defaultPort ?? 0
        let socket = try await Slots.elsewhere { try SocketAddress.makeAddressResolvingHost(address, port: port) }
        let connecting = MySQLConnection.connect(
            to: socket, username: db.user ?? "root", database: db.database ?? "", password: databaseConnection.password,
            tlsConfiguration: db.ssl == "disable" ? nil : DatabaseWire.tls, serverHostname: nil,
            logger: DatabaseWire.logger, on: DatabaseWire.eventLoop
        )
        // Limit: MySQLNIO doesn't hand out the channel before the handshake ends, so a handshake that never ends keeps
        // its socket until the far end closes it. A connection whose handshake ends late is closed then.
        do {
            return try await DatabaseWire.first(connecting, within: handshake, db) {
                connecting.whenSuccess { late in _ = late.close() }
            }
        } catch DatabaseFailure.failed(let said) where said.hasPrefix("No answer from") {
            // Said apart from a query past its time: nothing ran, so the user knows it's safe to try again.
            throw DatabaseFailure.failed(
                "\(db.name) took the connection but didn't finish logging in within \(Int(handshake.rounded(.up))) s.")
        }
    }

    /// Stops what connection `id` runs, from a connection of its own. Returns whether the server said it did.
    private static func kill(_ id: String?, _ databaseConnection: DatabaseConnection) async -> Bool {
        guard let id, Int(id) != nil else { return false }
        do {
            let conn = try await open(databaseConnection, handshake: killTimeout)
            var said: (any Error)?
            // A server that didn't answer the call may not answer this either, so the KILL has a time limit too
            do {
                _ = try await DatabaseWire.within(
                    killTimeout, databaseConnection.database,
                    close: { await DatabaseWire.close { try await conn.close().get() } }
                ) { try await run(conn, "KILL QUERY \(id)") }
            } catch { said = error }
            await DatabaseWire.close { try await conn.close().get() }
            if let said { throw said }
            return true
        } catch {
            Log.session.info("db: KILL QUERY on \(databaseConnection.database.name) failed: \(error)")
            return false
        }
    }

    /// Runs one statement over the text protocol and returns its columns (when it gave rows) and rows, with NULL as
    /// nil. Up to `keep` rows are kept as they come and the rest only counted, so a SELECT * of millions doesn't fill
    /// kelpd.
    static func run(_ conn: MySQLConnection, _ sql: String) async throws -> DatabaseRows {
        let kept = OSAllocatedUnfairLock(initialState: DatabaseRows())
        try await conn.simpleQuery(sql) { row in
            let names = row.columnDefinitions.map(\.name)
            let bytes = row.columnDefinitions.map { binary($0.characterSet, $0.columnType) }
            let values = zip(row.values, bytes).map { value, binary in value.map { text($0, binary: binary) } }
            // Hex isn't the value's own text, so an agent's change to such rows isn't kept to put back
            let hex = zip(row.values, bytes).contains { $0 != nil && $1 }
            kept.withLock {
                $0.add(columns: names, values)
                if hex { $0.opaque = true }
            }
        }.get()
        return kept.withLock { $0 }
    }

    /// A value as text. A binary string, a blob or a BIT comes as bytes, written as hex (0x…, the first 64 bytes of a
    /// longer one), as MySQL reads it back in SQL (`DatabaseInfo.Engine.literal(_:type:)`).
    static func text(_ value: ByteBuffer, binary: Bool) -> String {
        guard binary else { return String(buffer: value) }
        let shown = value.getBytes(at: value.readerIndex, length: min(value.readableBytes, PostgresText.byteaShown))
        let count = value.readableBytes
        return "0x" + (shown ?? []).map { String(format: "%02x", $0) }.joined()
            + (count > PostgresText.byteaShown ? "… (\(count) bytes)" : "")
    }

    /// Whether the column's values are bytes: the binary character set on a string, blob, BIT or geometry. A number
    /// has that character set too, and is text all the same.
    static func binary(_ set: MySQLProtocol.CharacterSet, _ type: MySQLProtocol.DataType) -> Bool {
        let bytes: [MySQLProtocol.DataType] = [
            .string, .varString, .varchar, .blob, .tinyBlob, .mediumBlob, .longBlob, .bit, .geometry
        ]
        return set == .binary && bytes.contains(type)
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
