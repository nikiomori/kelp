import Agents
import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

// What an agent's change does to its rows, kept with its trial: the rows as they were, the key that finds them.

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])

/// `orders` with three pending rows, `notes` without a key, `files` with a blob, in the project's db/ folder.
private func changeDB(in root: String) throws -> String {
    let dir = (root as NSString).appendingPathComponent("db")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("shop.sqlite3")
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT, note TEXT)")
        try db.execute(sql: "INSERT INTO orders VALUES (1, 'pending', NULL), (2, 'pending', 'gift'), (3, 'paid', NULL)")
        try db.execute(sql: "CREATE TABLE notes (text TEXT)")
        try db.execute(sql: "INSERT INTO notes VALUES ('a'), ('b')")
        try db.execute(sql: "CREATE TABLE files (id INTEGER PRIMARY KEY, body BLOB)")
        try db.execute(sql: "INSERT INTO files VALUES (1, x'0102')")
    }
    try queue.close()
    return path
}

private func orders(_ path: String) throws -> Int {
    try DatabaseQueue(path: path).read { try Int.fetchOne($0, sql: "SELECT count(*) FROM orders") ?? -1 }
}

private func latest(_ w: World, _ worktree: String) async throws -> (run: DatabaseRun, result: QueryResult?) {
    let run = try #require(try await w.c.call(DatabaseActivity(worktreeId: worktree)).runs.first)
    return (run, try await w.c.call(DatabaseResultRead(worktreeId: worktree, id: run.id)))
}

/// Agents change `shop` without asking.
private func free(_ w: World, _ worktree: String) async throws {
    var shop = try #require(try await w.c.call(DatabaseList(worktreeId: worktree)).first)
    shop.access = .free
    _ = try await w.c.call(DatabaseSave(worktreeId: worktree, database: shop))
}

/// The question's rows say what the update does: each row as it was beside what it becomes, found by the table's key,
/// and they stay with the run once it's allowed. The agent gets its rows, not the ones as they were.
@Test func anAskedUpdateKeepsItsRowsAsTheyWere() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    _ = try changeDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let update = DatabaseQuery(
        worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'cancelled' WHERE status = 'pending'")
    let asked = Task { try await w.d.workspaces.databases.query(update, origin: agent.id) }
    #expect(try await waitFor { try w.d.store.session(agent.id)?.summary.hasPrefix("Allow changing 2 rows") == true })
    let trial = try #require(try await latest(w, wt.id).result)
    #expect(trial.change?.kind == .update && trial.change?.table == "orders" && trial.change?.key == ["id"])
    #expect(trial.rows == [["1", "cancelled", nil], ["2", "cancelled", "gift"]])
    #expect(trial.change?.before == [["1", "pending", nil], ["2", "pending", "gift"]])
    #expect(trial.changedColumns == [1])
    let question = try w.d.store.session(agent.id)?.summary
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
    let sent = try await asked.value
    #expect(sent.changed == 2 && sent.change == nil)
    let done = try await latest(w, wt.id)
    #expect(done.run.state == .done && done.result?.change == trial.change)
}

/// Where agents change freely, a change is tried first all the same: a DELETE's rows are the ones it removed, an
/// INSERT's the ones it added, each with the key that finds them again.
@Test func aFreeChangeKeepsWhatItDidToItsRows() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try changeDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    try await free(w, wt.id)
    let dbs = w.d.workspaces.databases
    func run(_ sql: String) async throws -> QueryResult? {
        _ = try await dbs.query(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: sql), origin: agent.id)
        return try await latest(w, wt.id).result
    }
    let deleted = try #require(try await run("DELETE FROM orders WHERE id = 3"))
    #expect(deleted.change == RowChange(kind: .delete, table: "orders", key: ["id"]))
    #expect(deleted.rows == [["3", "paid", nil]])
    #expect(try orders(path) == 2)
    let added = try #require(try await run("INSERT INTO \"orders\" (status) VALUES ('new')"))
    #expect(added.change == RowChange(kind: .insert, table: "\"orders\"", key: ["id"]))
    #expect(added.rows.first?[1] == "new")
    // One row, not two: the trial was rolled back
    #expect(try orders(path) == 3)
}

/// No saying what to put back, so nothing is said: a change that may write over a row, a table without a key (rows
/// kept, no key), an update that moves its key (no rows as they were), a blob (shown as its size).
@Test func aChangeKelpCantPutBackSaysLess() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    _ = try changeDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    try await free(w, wt.id)
    let dbs = w.d.workspaces.databases
    func change(_ sql: String) async throws -> RowChange? {
        _ = try await dbs.query(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: sql), origin: agent.id)
        return try await latest(w, wt.id).result?.change
    }
    #expect(try await change("INSERT OR REPLACE INTO orders VALUES (1, 'paid', NULL)") == nil)
    #expect(try await change("UPDATE notes SET text = 'c'") == RowChange(kind: .update, table: "notes"))
    #expect(
        try await change("UPDATE orders SET id = id + 10") == RowChange(kind: .update, table: "orders", key: ["id"]))
    #expect(try await change("UPDATE files SET id = 2") == nil)
    #expect(try await change("CREATE TABLE t (a)") == nil)
}

@Test func aRowChangeIsOneTablesUpdateDeleteOrInsert() {
    func kind(_ sql: String, _ engine: DatabaseInfo.Engine = .postgres) -> RowChange.Kind? {
        Databases.kind(sql, engine)
    }
    #expect(kind("update orders set a = 1") == .update && kind("-- x\nDELETE FROM orders") == .delete)
    #expect(kind("INSERT INTO t VALUES (1)") == .insert)
    #expect(kind("INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET a = 1") == nil)
    #expect(kind("WITH x AS (SELECT 1) UPDATE t SET a = 1") == nil && kind("MERGE INTO t USING s ON true") == nil)
    #expect(kind("UPDATE t SET a = 1", .mysql) == nil)   // no RETURNING: no rows to say it with
    #expect(Databases.table("UPDATE \"Order Items\" SET a = 1", asWritten: true) == "\"Order Items\"")
}
