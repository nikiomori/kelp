import Core
import Foundation
import GRDB

/// Runs statements on a SQLite file inside kelpd itself, through GRDB.
struct SQLiteRun: DatabaseRunner {
    let connection: DatabaseConnection, off: Slots
    /// How long counting the rows of all tables may take for the schema. Past that time a table's count is left out
    /// (nil), so a file of many GB still shows its tables.
    var counting: TimeInterval = 3

    static func open(_ path: String, readOnly: Bool) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = readOnly
        config.busyMode = .timeout(5)
        config.label = "kelp.db"
        let queue = try DatabaseQueue(path: path, configuration: config)
        if !readOnly, let stop = DatabaseStop.current {
            queue.add(transactionObserver: StopRollsBack(stop: stop), extent: .databaseLifetime)
        }
        return queue
    }

    /// Rolls back what the user stopped instead of committing it, even where the Stop came before the statement ran,
    /// which SQLite's interrupt misses (and between a batch's statements).
    private final class StopRollsBack: TransactionObserver {
        let stop: DatabaseStop
        init(stop: DatabaseStop) { self.stop = stop }
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseWillCommit() throws {
            if stop.stopped { throw DatabaseFailure.failed(DatabaseCancel.stopped) }
        }
        func databaseDidCommit(_ db: Database) {}
        func databaseDidRollback(_ db: Database) {}
    }

    /// Each call is stopped when its time runs out (`interrupt`, from another thread), so a runaway join or UPDATE
    /// doesn't keep its slot or outlast the call that waits for it. SQLite undoes a statement it stops.
    func read(_ sql: String, timeout: TimeInterval) async throws -> DatabaseRows {
        let path = try DatabaseEngines.path(connection)
        return try await off.run {
            try Self.run {
                let queue = try Self.open(path, readOnly: true)
                return try Self.stopped(queue, after: timeout) {
                    try queue.read { db in
                        let statement = try db.makeStatement(sql: sql)
                        guard statement.isReadonly else { throw DatabaseFailure.change }
                        return try Self.rows(statement)
                    }
                }
            }
        }
    }

    func trial(_ sql: String) async throws -> DatabaseRows {
        let path = try DatabaseEngines.path(connection)
        return try await off.run {
            try Self.run {
                var result = DatabaseRows()
                let queue = try Self.open(path, readOnly: false)
                try Self.stopped(queue, after: DatabaseEngines.readTimeout) {
                    try queue.inDatabase { db in
                        try db.inTransaction {
                            let statement = try db.makeStatement(sql: SQLText.returning(sql) ?? sql)
                            result = try Self.rows(statement)
                            result.changed = db.changesCount
                            return .rollback
                        }
                    }
                }
                return result
            }
        }
    }

    /// Handles `allowed` as the Postgres runner does (`PostgresWire.write`), so it commits only if that many rows
    /// changed.
    func write(_ sql: String, allowed: Int?) async throws -> DatabaseRows {
        let path = try DatabaseEngines.path(connection)
        return try await off.run {
            try Self.run {
                let queue = try Self.open(path, readOnly: false)
                return try Self.stopped(queue, after: DatabaseEngines.writeTimeout) {
                    guard let allowed else {
                        return try queue.inDatabase { db in
                            var result = try Self.rows(try db.makeStatement(sql: sql))
                            result.changed = db.changesCount
                            return result
                        }
                    }
                    var result = DatabaseRows()
                    try queue.inTransaction { db in
                        result = try Self.rows(try db.makeStatement(sql: sql))
                        result.changed = db.changesCount
                        return result.changed == allowed ? .commit : .rollback
                    }
                    guard result.changed == allowed else { throw DatabaseEngines.notAsAllowed(result.changed, allowed) }
                    return result
                }
            }
        }
    }

    func apply(_ statements: [String]) async throws -> Int {
        let path = try DatabaseEngines.path(connection)
        return try await off.run {
            try Self.run {
                var changed = 0
                let queue = try Self.open(path, readOnly: false)
                try Self.stopped(queue, after: DatabaseEngines.writeTimeout) {
                    try queue.inTransaction { db in
                        for sql in statements {
                            try db.execute(sql: sql)
                            changed += db.changesCount
                        }
                        return .commit
                    }
                }
                return changed
            }
        }
    }

    /// Runs the statements in one transaction. A read reports no count (nil), and every other statement reports the
    /// rows it and its triggers changed.
    func batch(_ statements: [String], keep: @escaping @Sendable ([Int?]) -> Bool) async throws -> [Int?] {
        let path = try DatabaseEngines.path(connection)
        return try await off.run {
            try Self.run {
                var changed: [Int?] = []
                let queue = try Self.open(path, readOnly: false)
                try Self.stopped(queue, after: DatabaseEngines.writeTimeout) {
                    try queue.inTransaction { db in
                        for sql in statements {
                            let statement = try db.makeStatement(sql: sql)
                            guard !statement.isReadonly else {
                                changed.append(nil)
                                continue
                            }
                            let before = db.totalChangesCount
                            try statement.execute()
                            changed.append(db.totalChangesCount - before)
                        }
                        return keep(changed) ? .commit : .rollback
                    }
                }
                return changed
            }
        }
    }

    static func stopped<T>(_ queue: DatabaseQueue, after timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        let stop = DispatchWorkItem { queue.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        defer { stop.cancel() }
        do { return try DatabaseStop.during({ queue.interrupt() }, body) } catch let error as DatabaseError
            where error.resultCode == .SQLITE_INTERRUPT
        {
            if DatabaseStop.current?.stopped == true { throw DatabaseFailure.failed(DatabaseCancel.stopped) }
            throw DatabaseFailure.failed("It took more than \(Int(timeout)) s.")
        }
    }

    /// Makes a consistent copy of the file with SQLite's own backup, even while something writes to the file.
    static func copy(_ path: String, to target: String) throws {
        try run {
            let source = try open(path, readOnly: true)
            try source.backup(to: try DatabaseQueue(path: target))
        }
    }

    static func rows(_ statement: Statement) throws -> DatabaseRows {
        var result = DatabaseRows(columns: statement.columnNames)
        let cursor = try Row.fetchCursor(statement)
        while let row = try cursor.next() {
            let values = row.databaseValues
            if values.contains(where: { if case .blob = $0.storage { true } else { false } }) { result.opaque = true }
            result.add(values.map(DatabaseEngines.text))
            if result.total >= DatabaseEngines.countLimit { break }
        }
        return result
    }

    func schema() async throws -> DatabaseSchema {
        let path = try DatabaseEngines.path(connection)
        return try await off.run {
            try Self.run {
                let queue = try Self.open(path, readOnly: true)
                let until = Date().addingTimeInterval(counting)
                return try queue.read { db in
                    let views = Set(
                        try String.fetchAll(
                            db, sql: "SELECT name FROM sqlite_master WHERE type = 'view' AND name NOT LIKE 'sqlite_%'"))
                    let names = try String.fetchAll(
                        db,
                        sql:
                            "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
                            + " AND name NOT LIKE 'sqlite_%' ORDER BY name"
                    )
                    return DatabaseSchema(
                        tables: try names.map { name in
                            let view = views.contains(name)   // a view has no keys or indexes of its own
                            let keys = view ? [] : try db.foreignKeys(on: name)
                            let all = try db.columns(in: name)
                            // An INTEGER PRIMARY KEY is the rowid, so it is never NULL, with or without NOT NULL (a
                            // key of another type can be NULL)
                            let rowid = all.filter { $0.primaryKeyIndex > 0 }.count == 1
                            let columns = all.map { column in
                                DatabaseSchema.Column(
                                    name: column.name, type: column.type,
                                    nullable: !column.isNotNull
                                        && !(rowid && column.primaryKeyIndex > 0
                                            && column.type.uppercased() == "INTEGER"),
                                    primary: column.primaryKeyIndex > 0,
                                    references: Self.reference(keys, column.name))
                            }
                            let count = try Self.counted(queue, db, name, until: until)
                            return DatabaseSchema.Table(
                                name: name, rows: count, columns: columns,
                                indexes: view
                                    ? []
                                    : try db.indexes(on: name).map {
                                        "\($0.name) (\($0.columns.joined(separator: ", ")))"
                                    }, kind: view ? "view" : nil)
                        })
                }
            }
        }
    }

    /// The table and column a column refers to, "users.id": a key of several columns maps each to its own.
    static func reference(_ keys: [ForeignKeyInfo], _ column: String) -> String? {
        for key in keys {
            guard let at = key.originColumns.firstIndex(of: column), key.destinationColumns.indices.contains(at)
            else { continue }
            return key.destinationTable + "." + key.destinationColumns[at]
        }
        return nil
    }

    /// Counts a table's rows, or returns nil once `until` has passed (before counting starts, or while it counts).
    private static func counted(_ queue: DatabaseQueue, _ db: Database, _ table: String, until: Date) throws -> Int? {
        let left = until.timeIntervalSinceNow
        guard left > 0 else { return nil }
        do {
            return try stopped(queue, after: left) {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table.quotedDatabaseIdentifier)")
            }
        } catch DatabaseFailure.failed { return nil }   // the count was stopped at `until`
    }

    /// Runs `body` and turns a GRDB error into a failure in the database's own words.
    private static func run<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as DatabaseError {
            if error.resultCode == .SQLITE_READONLY { throw DatabaseFailure.change }
            throw DatabaseFailure.failed(error.message ?? error.description)
        }
    }
}
