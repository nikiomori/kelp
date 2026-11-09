import Core
import Foundation
import GRDB

/// A SQLite file in kelpd itself (GRDB).
enum SQLiteRun {
    static func open(_ path: String, readOnly: Bool) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = readOnly
        config.busyMode = .timeout(5)
        config.label = "kelp.db"
        return try DatabaseQueue(path: path, configuration: config)
    }

    /// Each stopped at its time (`interrupt`, from another thread): a runaway join or UPDATE doesn't keep its slot, nor
    /// outlast the call that waits for it. SQLite undoes a statement it stops.
    static func read(_ path: String, _ sql: String, timeout: TimeInterval) throws -> DatabaseRows {
        try run {
            let queue = try open(path, readOnly: true)
            return try stopped(queue, after: timeout) {
                try queue.read { db in
                    let statement = try db.makeStatement(sql: sql)
                    guard statement.isReadonly else { throw DatabaseFailure.change }
                    return try rows(statement)
                }
            }
        }
    }

    static func trial(_ path: String, _ sql: String) throws -> DatabaseRows {
        try run {
            var result = DatabaseRows()
            let queue = try open(path, readOnly: false)
            try stopped(queue, after: DatabaseEngines.readTimeout) {
                try queue.inDatabase { db in
                    try db.inTransaction {
                        let statement = try db.makeStatement(sql: SQLText.returning(sql) ?? sql)
                        result = try rows(statement)
                        result.changed = db.changesCount
                        return .rollback
                    }
                }
            }
            return result
        }
    }

    static func write(_ path: String, _ sql: String) throws -> DatabaseRows {
        try run {
            let queue = try open(path, readOnly: false)
            return try stopped(queue, after: DatabaseEngines.writeTimeout) {
                try queue.inDatabase { db in
                    var result = try rows(try db.makeStatement(sql: sql))
                    result.changed = db.changesCount
                    return result
                }
            }
        }
    }

    static func apply(_ path: String, _ statements: [String]) throws -> Int {
        try run {
            var changed = 0
            let queue = try open(path, readOnly: false)
            try stopped(queue, after: DatabaseEngines.writeTimeout) {
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

    static func stopped<T>(_ queue: DatabaseQueue, after timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        let stop = DispatchWorkItem { queue.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        defer { stop.cancel() }
        do { return try body() } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            throw DatabaseFailure.failed("It took more than \(Int(timeout)) s.")
        }
    }

    /// A consistent copy of the file, written or not while it's read (SQLite's own backup).
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
            result.total += 1
            if result.rows.count < DatabaseEngines.keep {
                result.rows.append(row.databaseValues.map(DatabaseEngines.text))
            }
            if result.total >= DatabaseEngines.countLimit { break }
        }
        return result
    }

    static func schema(_ path: String) throws -> DatabaseSchema {
        try run {
            try open(path, readOnly: true).read { db in
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
                        // INTEGER PRIMARY KEY is the rowid: never NULL, NOT NULL said or not (another key type can be)
                        let rowid = all.filter { $0.primaryKeyIndex > 0 }.count == 1
                        let columns = all.map { column in
                            DatabaseSchema.Column(
                                name: column.name, type: column.type,
                                nullable: !column.isNotNull
                                    && !(rowid && column.primaryKeyIndex > 0 && column.type.uppercased() == "INTEGER"),
                                primary: column.primaryKeyIndex > 0,
                                references: keys.first { $0.originColumns.contains(column.name) }.map {
                                    $0.destinationTable + "." + ($0.destinationColumns.first ?? "")
                                })
                        }
                        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(name.quotedDatabaseIdentifier)")
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

    /// GRDB's error as the database said it.
    private static func run<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as DatabaseError {
            if error.resultCode == .SQLITE_READONLY { throw DatabaseFailure.change }
            throw DatabaseFailure.failed(error.message ?? error.description)
        }
    }
}
