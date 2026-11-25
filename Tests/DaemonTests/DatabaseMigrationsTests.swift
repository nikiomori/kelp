import Core
import Foundation
import GRDB
import Testing

@testable import Daemon

// A database's migrations: what its tool's table says was applied, against the project's migrations folder.

private func write(_ files: [String: String], in root: String) throws {
    for (path, text) in files {
        let file = (root as NSString).appendingPathComponent(path)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }
}

/// A Rails project whose database has applied three of its five migrations: the schema read lists all five, oldest
/// first, the two not applied marked so, and the panel's event counts them.
@Test func aSchemaReadSaysWhichMigrationsArentApplied() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let main = try await firstWorkspace(w)
    let names = [
        "20261101000000_create_customers", "20261109000000_add_orders_status_index",
        "20261118000000_create_order_items",
        "20261122000000_add_paid_at", "20261124000000_backfill_paid_at"
    ]
    try write(Dictionary(uniqueKeysWithValues: names.map { ("db/migrate/\($0).rb", "") }), in: main.path)
    let queue = try DatabaseQueue(path: main.path + "/db/shop.sqlite3")
    try await queue.write { db in
        try db.execute(sql: "CREATE TABLE orders (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "CREATE TABLE schema_migrations (version TEXT PRIMARY KEY)")
        try db.execute(
            sql: "INSERT INTO schema_migrations VALUES ('20261101000000'), ('20261109000000'), ('20261118000000')")
    }
    try queue.close()

    let schema = try await w.c.call(DatabaseSchemaRead(worktreeId: main.id, database: "shop"))
    let migrations = try #require(schema.migrations)
    #expect(migrations.table == "schema_migrations")
    #expect(migrations.all.map(\.name) == names.map { String($0.drop { $0 != "_" }.dropFirst()) })
    #expect(migrations.all.map(\.applied) == [true, true, true, false, false])
    #expect(migrations.line.hasPrefix("2 migrations not applied (schema_migrations): 20261122000000 add_paid_at, "))
    #expect(try await w.c.call(DatabaseActivity(worktreeId: main.id)).migrations == ["shop": 2])
    // One table's read leaves them out: they are the whole schema's
    #expect(
        try await w.c.call(DatabaseSchemaRead(worktreeId: main.id, database: "shop", table: "orders")).migrations
            == nil)
}

/// Each tool's table and folder, read the way the tool reads them: which of the folder's migrations are applied.
@Test(arguments: [
    // Prisma keeps each migration's folder name, and a rolled-back one isn't applied (the read leaves it out)
    (
        MigrationTool.prisma,
        ["prisma/migrations/20261101_init/migration.sql": "", "prisma/migrations/20261122_paid/x": ""],
        [["20261101_init"]], ["20261101": true, "20261122": false]
    ),
    // Django names each app's migrations by the folder they're in; a library's own app (auth) is only in the table
    (
        .django,
        ["shop/migrations/0001_initial.py": "", "shop/migrations/0002_paid.py": "", "shop/migrations/__init__.py": ""],
        [["shop", "0001_initial"], ["auth", "0001_initial"]], ["shop 0001": true, "shop 0002": false, "auth 0001": true]
    ),
    // Alembic's table holds the head only: what it follows is applied too
    (
        .alembic,
        [
            "alembic/versions/a1_init.py": "revision = 'a1'\ndown_revision = None\n",
            "alembic/versions/b2_paid.py": "revision: str = 'b2'\ndown_revision: Union[str, None] = 'a1'\n",
            "alembic/versions/c3_more.py": "revision = \"c3\"\ndown_revision = 'b2'\n"
        ],
        [["b2"]], ["a1": true, "b2": true, "c3": false]
    ),
    // Drizzle's table holds when each ran: what its journal made up to then is applied
    (
        .drizzle,
        [
            "drizzle/meta/_journal.json":
                #"{"entries":[{"idx":0,"when":100,"tag":"0000_init"},{"idx":1,"when":200,"tag":"0001_paid"}]}"#
        ],
        [["100"]], ["0000": true, "0001": false]
    ),
    (
        .laravel,
        [
            "database/migrations/2026_11_01_000000_create_users.php": "",
            "database/migrations/2026_11_22_000000_add_paid_at.php": ""
        ],
        [["2026_11_01_000000_create_users"]], ["2026_11_01_000000": true, "2026_11_22_000000": false]
    )
])
func eachToolsMigrationsAreReadAsItReadsThem(
    tool: MigrationTool, files: [String: String], rows: [[String?]], applied: [String: Bool]
) throws {
    let root = NSTemporaryDirectory() + "kelp-migrations-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: root) }
    try write(files, in: root)
    let all = tool.status(table: tool.table.name, rows: rows, root: root).all
    #expect(Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.applied) }) == applied)
    if tool == .alembic { #expect(all.map(\.name) == ["init", "paid", "more"]) }   // in the chain's order
}

/// An app's own table named "migrations" isn't Laravel's unless it has Laravel's column.
@Test func onlyAToolsOwnTableIsTakenForIt() {
    let theirs = DatabaseSchema.Table(
        name: "migrations", columns: [.init(name: "migration", type: "TEXT", nullable: false, primary: false)])
    let mine = DatabaseSchema.Table(
        name: "migrations", columns: [.init(name: "step", type: "TEXT", nullable: false, primary: false)])
    #expect(MigrationTool.of(DatabaseSchema(tables: [theirs]))?.tool == .laravel)
    #expect(MigrationTool.of(DatabaseSchema(tables: [mine])) == nil)
}
