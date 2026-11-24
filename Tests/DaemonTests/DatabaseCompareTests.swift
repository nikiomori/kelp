import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

// How a branch's copy differs from the database it copies (`db.diff`): columns and row counts, table by table.

/// A copy whose agent added a column, a table and two migrations' rows, and deleted twelve items: `kelp db diff` says
/// so line by line, the tables the same in both left out.
@Test func aBranchesCopySaysHowItDiffersFromItsDatabase() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let main = try await firstWorkspace(w)
    let dir = main.path + "/db"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: dir + "/shop.sqlite3")
    try await queue.write { db in
        try db.execute(sql: "CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL)")
        try db.execute(sql: "CREATE TABLE order_items (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "CREATE TABLE customers (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "CREATE TABLE schema_migrations (version TEXT PRIMARY KEY)")
        for i in 1...20 { try db.execute(sql: "INSERT INTO order_items VALUES (?)", arguments: [i]) }
    }
    try queue.close()
    let branch = try await workspace(w, "feature/paid-at")
    let copy = try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "shop"))
    let mine = try DatabaseQueue(path: try #require(copy.path))
    try await mine.write { db in
        try db.execute(sql: "ALTER TABLE orders ADD COLUMN paid_at TEXT")
        try db.execute(sql: "CREATE TABLE refunds (id INTEGER PRIMARY KEY)")
        for i in 1...37 { try db.execute(sql: "INSERT INTO refunds VALUES (?)", arguments: [i]) }
        try db.execute(sql: "DELETE FROM order_items WHERE id <= 12")
        try db.execute(sql: "INSERT INTO schema_migrations VALUES ('20261122'), ('20261124')")
    }
    try mine.close()

    let diff = try await w.c.call(DatabaseDiff(worktreeId: branch.id))
    #expect(
        diff.text == """
            shop for feature/paid-at against shop
            orders             + paid_at TEXT
            refunds            new table, 37 rows
            order_items        12 rows fewer
            schema_migrations  2 rows more
            """)
    #expect(diff.tables.first { $0.name == "customers" }?.same == true)

    // Hidden from agents, neither is compared for one; the user still compares them. The original hidden alone is
    // refused too, though the copy isn't hidden.
    var project = try #require(try await w.c.call(DatabaseList(worktreeId: main.id)).first)
    project.access = .hidden
    _ = try await w.c.call(DatabaseSave(worktreeId: main.id, database: project))
    await expectRefusal(says: "no databases Kelp knows of") {
        try await w.d.workspaces.databases.compare(branch.id, nil, agent: true)
    }
    var hidden = try #require(try await w.c.call(DatabaseList(worktreeId: branch.id)).first)
    hidden.access = .hidden
    _ = try await w.c.call(DatabaseSave(worktreeId: branch.id, database: hidden))
    await expectRefusal(says: "no copy of a database") {
        try await w.d.workspaces.databases.compare(branch.id, nil, agent: true)
    }
    await expectRefusal(says: "no databases Kelp knows of") {
        try await w.d.workspaces.databases.compare(branch.id, "shop", agent: true)
    }
    #expect(try await w.c.call(DatabaseDiff(worktreeId: branch.id, database: "shop")).copy == "shop")
}

/// The columns that differ in a table both have: added, dropped, and a type changed.
@Test func aTablesColumnsSayWhatChanged() {
    func column(_ name: String, _ type: String) -> DatabaseSchema.Column {
        .init(name: name, type: type, nullable: true, primary: false)
    }
    #expect(
        Databases.columns(
            [column("id", "INTEGER"), column("total", "REAL"), column("paid_at", "TEXT")],
            [column("id", "INTEGER"), column("total", "INTEGER"), column("note", "TEXT")])
            == ["total INTEGER → REAL", "+ paid_at TEXT", "− note TEXT"])
}

/// A production original's rows aren't counted one by one (an exact COUNT(*) reads each table whole): the schema's
/// own numbers stand.
@Test func aProductionOriginalIsntCounted() {
    let tables = [DatabaseSchema.Table(name: "orders", rows: 12, columns: [])]
    var db = DatabaseInfo(name: "app", engine: .postgres)
    #expect(Databases.counting(tables, db)?.contains("COUNT(*)") == true)
    db.production = true
    #expect(Databases.counting(tables, db) == nil)
}
