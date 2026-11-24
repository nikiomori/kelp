import Agents
import Core
import Foundation
import GRDB
import GitKit
import TestSupport
import Testing

@testable import Daemon

// Undo Turn puts the project's database back with the files: a SQLite file kept as the turn began, a branch's
// Postgres copy kept before the turn's first change.

/// A SQLite file in WAL mode, ignored by git as a project's database is, held open the way a dev server holds it.
private func shop(in root: String) throws -> (path: String, server: DatabasePool) {
    try FileManager.default.createDirectory(atPath: root + "/db", withIntermediateDirectories: true)
    try "db/\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    let path = root + "/db/shop.sqlite3", server = try DatabasePool(path: path)
    try server.write { db in
        try db.execute(sql: "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)")
        try db.execute(sql: "INSERT INTO orders VALUES (1, 'pending'), (2, 'pending')")
    }
    return (path, server)
}

private func orders(_ path: String) throws -> [String] {
    let queue = try DatabaseQueue(path: path)
    defer { try? queue.close() }
    return try queue.read { db in
        let columns = try db.columns(in: "orders").map(\.name)
        return try String.fetchAll(db, sql: "SELECT id || ':' || status FROM orders ORDER BY id") + columns
    }
}

/// The file is kept once as the turn begins, whatever the turn does; the sheet says what the agent did; Put Back
/// brings back its rows and columns, the server's own write still in the log included; Redo takes that back.
@Test func undoingATurnPutsItsDatabaseBack() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let (path, server) = try shop(in: wt.path)
    var shopDB = try #require(try await w.c.call(DatabaseList(worktreeId: wt.id)).first)
    shopDB.access = .free
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: shopDB))
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    let keeps = w.d.sessions.turns.databases
    live.noteTurn(.working)
    #expect(try await waitFor(5) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty })
    let turn = try #require(try await w.c.call(SessionTurns(id: s.id)).first)
    #expect(keeps.kept(turn.id).map(\.name) == ["shop"])
    let before = try orders(path)

    let dbs = w.d.workspaces.databases
    for sql in ["UPDATE orders SET status = 'paid'", "ALTER TABLE orders ADD COLUMN paid_at TEXT"] {
        _ = try await dbs.query(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: sql), origin: s.id)
    }
    // The project's code writes too
    try await server.write { try $0.execute(sql: "INSERT INTO orders (id, status) VALUES (3, 'new')") }
    live.noteTurn(.waiting)
    live.noteTurn(.working)   // the same turn: nothing is kept again
    live.noteTurn(.idle)
    await saved(w, s.id)
    #expect(try await w.c.call(SessionTurns(id: s.id)).count == 1 && keeps.kept(turn.id).count == 1)
    #expect(keeps.kept(turn.id).first?.runs.count == 2)

    let plan = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    #expect(plan.files.isEmpty)   // ignored by git: only the database goes back
    #expect(
        plan.databases == [
            .init(
                name: "shop.sqlite3", detail: "Agent changed it 2 times in this turn: 2 rows of orders, 1 new column.")
        ])
    let after = try orders(path)
    let undone = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id, apply: true, state: plan.state))
    #expect(try orders(path) == before)
    // The server, still open, reads it too
    #expect(try await server.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM orders") } == 2)
    _ = try await w.c.call(SessionTurnRedo(id: s.id, turn: turn.id, state: undone.state))
    #expect(try orders(path) == after)
    try server.close()
}

/// Kelp keeps a turn's databases as long as the turn is listed: the last 20.
@Test func aTurnsDatabasesGoWithTheTurn() async throws {
    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let (_, server) = try shop(in: wt.path)
    defer { try? server.close() }
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let tree = try Git.snapshotTree(wt.path, remotes: .none), turns = w.d.sessions.turns
    let marks = (0..<21).map { i in
        SessionTurns.Mark(
            session: s.id, tree: tree, head: nil, folder: wt.path, prompt: "\(i)",
            at: Date(timeIntervalSinceNow: Double(i)))
    }
    for mark in marks { turns.keep(mark, staged: nil) }
    let kept = { (mark: SessionTurns.Mark) in
        FileManager.default.fileExists(atPath: turns.databases.folder(mark.id).path)
    }
    #expect(!kept(marks[0]) && marks.dropFirst().allSatisfy(kept))
    turns.dropRefs(of: s.id)
    #expect(!marks.contains(where: kept))
}

/// What the sheet says the agent did, from the turn's runs: rows by table where a change names one, columns added,
/// and nothing it can't tell.
@Test(
    arguments: [
        (
            [
                "UPDATE orders SET paid = 1": 214, "ALTER TABLE orders ADD COLUMN paid_at timestamptz": 0,
                "DELETE FROM orders": 0
            ],
            "Claude changed it 3 times in this turn: 214 rows of orders, 1 new column."
        ),
        (["INSERT INTO customers VALUES (1)": 1], "Claude changed it once in this turn: 1 row of customers."),
        (["UPDATE a SET x = 1; UPDATE b SET y = 2": 5], "Claude changed it once in this turn."),
        (
            ["ALTER TABLE t ADD COLUMN a int, ADD b int, ADD CONSTRAINT c UNIQUE (a)": 0],
            "Claude changed it once in this turn: 2 new columns."
        ),
        ([:], nil)
    ] as [([String: Int], String?)])
func theSheetSaysWhatTheAgentDid(runs: [String: Int], said: String?) {
    let ordered = runs.sorted { $0.key > $1.key }.map { sql, changed in
        DatabaseRun(
            id: sql, database: "shop", sql: sql, session: "s", at: Date(), state: .done, changed: changed)
    }
    #expect(Databases.said(agent: "Claude", ordered, .postgres) == said)
}

/// A branch's Postgres copy is kept with TEMPLATE, which Postgres refuses while anything is connected: the sheet then
/// says it can't go back. (No server runs here: the copy's address answers nobody, and the SQL is checked as text.)
@Test func aPostgresCopyThatCantBeKeptIsSaid() async throws {
    #expect(
        Databases.undoSQL("app_fix", template: "kelp_t", aside: "kelp_u")
            == (
                #"ALTER DATABASE "app_fix" RENAME TO "kelp_u""#, #"CREATE DATABASE "app_fix" TEMPLATE "kelp_t""#,
                #"ALTER DATABASE "kelp_u" RENAME TO "app_fix""#
            ))
    #expect(Databases.dropSQL("kelp_t") == #"DROP DATABASE IF EXISTS "kelp_t""#)
    #expect(
        Databases.templateName("undone-" + UUID().uuidString, String(repeating: "long_name", count: 9)).utf8.count <= 63
    )

    let w = try await world(agents: [AgentManifest(id: "claude-like", name: "Agent", command: "/bin/cat")])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    var copy = DatabaseInfo(name: "app_fix", engine: .postgres)
    (copy.host, copy.port, copy.database, copy.user) = ("127.0.0.1", 1, "app_fix", "app")
    copy.copy = BranchCopy(of: "app", worktreeId: wt.id, at: Date())
    copy.access = .free
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: copy))
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "claude-like"]), as: Session.self)
    let live = try #require(w.d.sessions.existing(s.id))
    live.noteTurn(.working)
    #expect(try await waitFor(5) { !(try await w.c.call(SessionTurns(id: s.id))).isEmpty })
    let turn = try #require(try await w.c.call(SessionTurns(id: s.id)).first)
    let change = DatabaseQuery(worktreeId: wt.id, database: "app_fix", sql: "UPDATE a SET x = 1; UPDATE b SET y = 2")
    _ = try? await w.d.workspaces.databases.query(change, origin: s.id)
    live.noteTurn(.idle)
    await saved(w, s.id)
    let plan = try await w.c.call(SessionTurnUndo(id: s.id, turn: turn.id))
    let said = try #require(plan.databases?.first)
    #expect(
        said.name == "app_fix"
            && said.cannot?.hasPrefix("Postgres couldn't copy it before the turn's first change") == true)
}

/// A DuckDB file goes back by a clone moved over it: a clone that fails leaves the file and its log as they were; one
/// that works brings back the file, and a log the kept file had none of goes.
@Test func aDuckDBFileThatCantGoBackStaysAsItWas() throws {
    let dir = tmp().appendingPathComponent("duck-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let live = dir + "/shop.duckdb", kept = dir + "/kept.db"
    try "live".write(toFile: live, atomically: true, encoding: .utf8)
    try "log".write(toFile: live + ".wal", atomically: true, encoding: .utf8)
    #expect(throws: DatabaseFailure.self) { try TurnDatabases.putBack(live, .duckdb, from: dir + "/gone.db") }
    #expect(try String(contentsOfFile: live, encoding: .utf8) == "live")
    #expect(try String(contentsOfFile: live + ".wal", encoding: .utf8) == "log")
    try "kept".write(toFile: kept, atomically: true, encoding: .utf8)
    try TurnDatabases.putBack(live, .duckdb, from: kept)
    #expect(try String(contentsOfFile: live, encoding: .utf8) == "kept")
    #expect(!FileManager.default.fileExists(atPath: live + ".wal"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["kept.db", "shop.duckdb"])
}

/// A branch's Postgres copy that goes takes the copies turns kept of it along (which only its address reaches): each
/// turn that kept one hands it over, and its undo then says why that copy can't go back.
@Test func aRemovedCopysTurnTemplatesAreHandedOver() throws {
    let keeps = TurnDatabases(root: tmp().appendingPathComponent("turns-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: keeps.dir) }
    func kept(_ name: String, _ template: String, in worktreeId: String = "w1") -> KeptDatabase {
        KeptDatabase(worktreeId: worktreeId, name: name, engine: .postgres, template: template)
    }
    try keeps.change("t1") { $0 = [kept("app_fix", "kelp_t1_app_fix"), kept("other", "kelp_t1_other")] }
    try keeps.change("t2") { $0 = [kept("app_fix", "kelp_t2_app_fix"), kept("app_fix", "kelp_t2_w2", in: "w2")] }
    #expect(keeps.takeTemplates(of: "app_fix", in: "w1").sorted() == ["kelp_t1_app_fix", "kelp_t2_app_fix"])
    #expect(keeps.kept("t1").map(\.template) == [nil, "kelp_t1_other"])
    #expect(keeps.kept("t2").map(\.template) == [nil, "kelp_t2_w2"])
    #expect(keeps.kept("t1").first?.cannot == "Its branch's copy was removed.")
    #expect(keeps.takeTemplates(of: "app_fix", in: "w1").isEmpty)
}
