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

/// `orders`' rows as Kelp says them, read from the file itself.
private func table(_ path: String, where rows: String = "1") throws -> [[String?]] {
    try DatabaseQueue(path: path).read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM orders WHERE \(rows) ORDER BY id").map {
            $0.databaseValues.map(DatabaseEngines.text)
        }
    }
}

/// A value made as the change runs (random(), a clock, a sequence's next id) is another in its trial: the rows the
/// agent is answered with, and the ones kept for History and Undo, are the rows the change wrote, where the database
/// asks and where it doesn't. Undo This Change then finds them by their key and puts back what was there.
@Test func aChangeIsAnsweredAndKeptWithTheRowsItWrote() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try changeDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let seeded = try table(path)
    /// `sql` run as the agent, allowed when it's asked (`question`); what it was answered, and what's kept of it.
    func change(_ sql: String, asking question: String?) async throws -> (sent: QueryResult, kept: QueryResult) {
        let running = Task {
            try await w.d.workspaces.databases.query(
                DatabaseQuery(worktreeId: wt.id, database: "shop", sql: sql), origin: agent.id)
        }
        if let question {
            #expect(try await waitFor { try w.d.store.session(agent.id)?.summary == question })
            #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
        }
        return (try await running.value, try #require(try await latest(w, wt.id).result))
    }
    /// As Undo This Change does it (the tab's `db.apply`): a row is put back by its key, and only while it's as the
    /// change left it (`DatabaseUndo.unchanged`, here each statement's own condition).
    func undo(_ statements: [String]) async throws {
        _ = try await w.c.call(DatabaseApply(worktreeId: wt.id, database: "shop", statements: statements))
    }
    for asks in [true, false] {
        if !asks { try await free(w, wt.id) }
        let updated = try await change(
            "UPDATE orders SET note = random() WHERE status = 'pending'",
            asking: asks ? "Allow changing 2 rows of orders in shop?" : nil)
        let written = try table(path, where: "status = 'pending'")
        #expect(written.map { $0[2] } != seeded.prefix(2).map { $0[2] }, "asks: \(asks)")
        #expect(updated.sent.rows == written && updated.sent.changed == 2, "asks: \(asks)")
        #expect(updated.kept.rows == written, "asks: \(asks)")
        #expect(updated.kept.change?.before == Array(seeded.prefix(2)) && updated.kept.changedColumns == [2])
        try await undo(
            zip(updated.kept.change?.before ?? [], updated.kept.rows).map { was, now in
                "UPDATE orders SET note = \(DatabaseInfo.Engine.sqlite.literal(was[2])) WHERE id = \(now[0] ?? "")"
                    + " AND note = \(DatabaseInfo.Engine.sqlite.literal(now[2]))"
            })
        #expect(try table(path) == seeded, "asks: \(asks)")

        let added = try await change(
            "INSERT INTO orders (status, note) VALUES ('new', random())",
            asking: asks ? "Allow changing 1 row of orders in shop?" : nil)
        let new = try table(path, where: "status = 'new'")
        #expect(new.count == 1 && added.sent.rows == new && added.kept.rows == new, "asks: \(asks)")
        #expect(added.kept.change == RowChange(kind: .insert, table: "orders", key: ["id"]))
        try await undo(
            added.kept.rows.map {
                "DELETE FROM orders WHERE id = \($0[0] ?? "") AND note = \(DatabaseInfo.Engine.sqlite.literal($0[2]))"
            })
        #expect(try table(path) == seeded, "asks: \(asks)")
    }
}

/// DuckDB's write asks for its rows itself and holds the change to the rows allowed through them, so it's sent the
/// statement as it is: its rows are the ones it wrote all the same. Where duckdb is installed (not on CI).
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/duckdb")))
func aDuckDBChangeIsKeptWithTheRowsItWrote() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    try FileManager.default.createDirectory(atPath: wt.path + "/data", withIntermediateDirectories: true)
    let made = try await Subprocess.run(
        [
            "/opt/homebrew/bin/duckdb", wt.path + "/data/shop.duckdb", "-c",
            "CREATE TABLE orders (id INT PRIMARY KEY, note VARCHAR); INSERT INTO orders VALUES (1, 'a'), (2, 'b');"
        ], cwd: "/", env: ["HOME": NSHomeDirectory()], timeLimit: 30)
    #expect(made.status == 0)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let update = DatabaseQuery(
        worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET note = CAST(uuid() AS VARCHAR) WHERE id = 2")
    let asked = Task { try await w.d.workspaces.databases.query(update, origin: agent.id) }
    let question = "Allow changing 1 row of orders in shop?"
    #expect(try await waitFor(15) { try w.d.store.session(agent.id)?.summary == question })
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
    let sent = try await asked.value
    let kept = try #require(try await latest(w, wt.id).result)
    let now = try await w.c.call(
        DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "SELECT * FROM orders WHERE id = 2"))
    #expect(sent.changed == 1 && sent.rows == now.rows && kept.rows == now.rows)
    #expect(kept.change == RowChange(kind: .update, table: "orders", key: ["id"], before: [["2", "b"]]))
}

/// What a change wrote keeps its rows as they were by their key: in another order than its trial's they're found
/// again, and a row the trial didn't change has none, so there's nothing to put back.
@Test func whatAChangeWroteKeepsItsRowsAsTheyWereByTheirKey() {
    var tried = QueryResult(id: "r", columns: ["id", "v"], rows: [["1", "a"], ["2", "b"]], total: 2, changed: 2, ms: 0)
    tried.change = RowChange(kind: .update, table: "t", key: ["id"], before: [["1", "x"], ["2", "y"]])
    func wrote(_ rows: [[String?]], columns: [String] = ["id", "v"]) -> DatabaseRows {
        DatabaseRows(columns: columns, rows: rows, total: rows.count, changed: rows.count)
    }
    #expect(Databases.written(tried, wrote([["2", "c"], ["1", "d"]]))?.before == [["2", "y"], ["1", "x"]])
    #expect(
        Databases.written(tried, wrote([["1", "d"], ["3", "c"]])) == RowChange(kind: .update, table: "t", key: ["id"]))
    // Not every row kept, none written, other columns than the trial's: no saying what it did
    var many = wrote([["1", "d"]])
    many.total = 2
    #expect(Databases.written(tried, many) == nil && Databases.written(tried, wrote([])) == nil)
    #expect(Databases.written(tried, wrote([["1"]], columns: ["id"])) == nil)
    tried.change = nil
    #expect(Databases.written(tried, wrote([["1", "d"]])) == nil)
}

/// The change says its rows itself (RETURNING *) where its trial did; as it is where the trial gave none (MySQL, a
/// Postgres view), where it says them already, and for DuckDB, whose write asks for them.
@Test func aTriedChangeSaysTheRowsItWrites() {
    let update = "UPDATE t SET at = now() WHERE id = 1 -- touch"
    let rows = QueryResult(id: "r", columns: ["id", "at"], rows: [["1", "2026-11-15"]], total: 1, changed: 1, ms: 0)
    let none = QueryResult(id: "r", columns: [], rows: [], total: 0, changed: 1, ms: 0)
    for engine in [DatabaseInfo.Engine.postgres, .sqlite] {
        #expect(Databases.saying(update, engine, tried: rows) == update + "\nRETURNING *")
        #expect(Databases.saying("INSERT INTO t DEFAULT VALUES", engine, tried: rows).hasSuffix("\nRETURNING *"))
        #expect(Databases.saying(update, engine, tried: none) == update)   // RETURNING didn't fit its trial
        #expect(Databases.saying(update, engine, tried: nil) == update)   // not tried: the user's own, a blob
        let own = "DELETE FROM t RETURNING id"
        #expect(Databases.saying(own, engine, tried: rows) == own)
    }
    for engine in [DatabaseInfo.Engine.mysql, .appwrite, .duckdb] {
        #expect(
            Databases.saying(update, engine, tried: rows) == update
                && Databases.saying(update, engine, tried: none) == update)
    }
    // psql's answer to it, in a compose container: the rows, then the tag with the rows it changed
    let said = PostgresRun.section("id,at\n8,2026-11-15 10:00:00+00\nINSERT 0 1\n")
    #expect(said.columns == ["id", "at"] && said.rows == [["8", "2026-11-15 10:00:00+00"]] && said.changed == 1)
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
    #expect(kind("UPDATE t SET a = 1, b = 2 RETURNING a") == nil)   // its own: b isn't among the rows
    #expect(Databases.table("UPDATE \"Order Items\" SET a = 1", asWritten: true) == "\"Order Items\"")
}

/// Undo This Change's statements, each found as it was checked, are kept only if every one finds its row (`each: 1`):
/// one row changed while the question was up, none of them is written, and the rows stay as they are.
@Test func anUndoWhoseRowChangedSinceWritesNothing() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try changeDB(in: wt.path)
    let undo = [
        "UPDATE orders SET status = 'pending' WHERE id = 1 AND status = 'cancelled'",
        "UPDATE orders SET status = 'pending' WHERE id = 3 AND status = 'paid'"
    ]
    await #expect(throws: RPCError.self) {
        try await w.c.call(DatabaseApply(worktreeId: wt.id, database: "shop", statements: undo, each: 1))
    }
    #expect(try table(path).map { $0[1] } == ["pending", "pending", "paid"])
    let undone = try await w.c.call(
        DatabaseApply(
            worktreeId: wt.id, database: "shop", statements: [undo[1], "DELETE FROM orders WHERE id = 2"], each: 1))
    #expect(undone.changed == 2)
    #expect(try table(path).map { $0[1] } == ["pending", "pending"])
}
