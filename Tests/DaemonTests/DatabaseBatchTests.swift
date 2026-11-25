import Agents
import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

// Several statements in one call: one change, tried, asked about and run together.

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])

/// `orders` with three pending rows and `users` with one, in the project's db/ folder.
private func batchDB(in root: String) throws -> String {
    let dir = (root as NSString).appendingPathComponent("db")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("shop.sqlite3")
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute(sql: "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)")
        try db.execute(sql: "INSERT INTO users VALUES (1, 'ann')")
        try db.execute(sql: "INSERT INTO orders VALUES (1, 'pending'), (2, 'pending'), (3, 'pending')")
    }
    try queue.close()
    return path
}

private func count(_ path: String, _ sql: String) throws -> Int {
    try DatabaseQueue(path: path).read { try Int.fetchOne($0, sql: sql) ?? -1 }
}

private func summary(_ w: World, _ id: String) throws -> String { try w.d.store.session(id)?.summary ?? "" }

private func several(_ worktree: String, _ sql: String) -> DatabaseQuery {
    DatabaseQuery(worktreeId: worktree, database: "shop", sql: sql)
}

/// The user's own statements run in one transaction, each saying the rows it changed (a read says none); one that
/// fails leaves none of them done.
@Test func severalStatementsAreKeptTogetherOrNotAtAll() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try batchDB(in: wt.path)
    let dbs = w.d.workspaces.databases
    let done = try await dbs.query(
        several(wt.id, "UPDATE orders SET status = 'paid' WHERE id = 1; DELETE FROM users; SELECT 1"), origin: nil)
    #expect(done.statements?.map(\.changed) == [1, 1, nil] && done.changed == 2)
    #expect(done.statements?.first?.sql == "UPDATE orders SET status = 'paid' WHERE id = 1")
    #expect(try count(path, "SELECT count(*) FROM users") == 0)
    await #expect(throws: RPCError.self) {
        try await dbs.query(several(wt.id, "DELETE FROM orders; INSERT INTO nope VALUES (1)"), origin: nil)
    }
    #expect(try count(path, "SELECT count(*) FROM orders") == 3)
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first?.state == .failed)
}

/// An agent's are asked about once, by what they'd change together; nothing is changed until the user allows them,
/// and then all are.
@Test func anAgentsStatementsAreAskedAboutOnce() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try batchDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let asked = Task {
        try await w.d.workspaces.databases.query(
            several(wt.id, "UPDATE orders SET status = 'paid'; DELETE FROM users"), origin: agent.id)
    }
    #expect(try await waitFor { try summary(w, agent.id) == "Allow 2 statements changing 4 rows in shop?" })
    let run = try #require(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first)
    let tried = try await w.c.call(DatabaseResultRead(worktreeId: wt.id, id: run.id))
    #expect(run.state == .asks && tried?.statements?.map(\.changed) == [3, 1])
    #expect(try count(path, "SELECT count(*) FROM users") == 1)   // tried, then rolled back
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: try summary(w, agent.id))))
    #expect(try await asked.value.changed == 4)
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'paid'") == 3)
    #expect(try count(path, "SELECT count(*) FROM users") == 0)
}

/// Statements asked about together carry the first risky one's line: a DROP after a read is said, its rows counted.
@Test func severalStatementsSayTheFirstRiskyOnesLine() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    _ = try batchDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let asked = Task {
        try await w.d.workspaces.databases.query(several(wt.id, "SELECT 1; DROP TABLE users"), origin: agent.id)
    }
    #expect(try await waitFor { try summary(w, agent.id).hasPrefix("Allow 2 statements") })
    let run = try #require(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first)
    let tried = try await w.c.call(DatabaseResultRead(worktreeId: wt.id, id: run.id))
    #expect(tried?.risk == ChangeRisk(kind: .drop, table: "users", values: 1))
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "deny", question: try summary(w, agent.id))))
    _ = try? await asked.value
}

/// The tables changed while it was asked: what the user allowed isn't what it would change now, so none of it runs.
@Test func statementsThatWouldChangeOtherRowsNowArentRun() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try batchDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let asked = Task {
        try await w.d.workspaces.databases.query(
            several(wt.id, "DELETE FROM users; UPDATE orders SET status = 'paid'"), origin: agent.id)
    }
    #expect(try await waitFor { try summary(w, agent.id).hasPrefix("Allow 2 statements") })
    try await DatabaseQueue(path: path).write { try $0.execute(sql: "INSERT INTO orders VALUES (4, 'pending')") }
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: try summary(w, agent.id))))
    do {
        _ = try await asked.value
        Issue.record("statements that would change other rows ran")
    } catch { #expect("\(error)".contains("not the 4 rows the user allowed")) }
    #expect(try count(path, "SELECT count(*) FROM users") == 1)
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'paid'") == 0)
}

@Test func severalStatementsAreReadAsTheirEngineReadsThem() throws {
    #expect(try SQLText.several("SELECT 1;", .sqlite) == ["SELECT 1"])
    #expect(
        try SQLText.several("UPDATE a SET x = ';'; -- note\nDELETE FROM b;", .postgres)
            == ["UPDATE a SET x = ';'", "-- note\nDELETE FROM b"])
    // They run in Kelp's transaction: none of them starts, ends or hands over one
    for sql in [
        "BEGIN; UPDATE a SET x = 1; COMMIT", "UPDATE a SET x = 1; /* x */ rollback",
        "DELETE FROM a; PREPARE TRANSACTION 't'"
    ] {
        #expect(throws: DatabaseFailure.self, "\(sql)") { try SQLText.several(sql, .postgres) }
    }
    // MySQL reads \' as a quote only when backslashes escape: where they end isn't sure
    #expect(throws: DatabaseFailure.self) { try SQLText.several(#"UPDATE a SET x = 'it\'s; DELETE FROM b"#, .mysql) }
    #expect(throws: DatabaseFailure.self) { try SQLText.several("SELECT 1; \\! rm -rf ~", .mysql) }
    #expect(
        Databases.question(statements: 3, database: "app", changed: 40) == "Allow 3 statements changing 40 rows in app?"
    )
    #expect(Databases.question(statements: 2, database: "app", changed: nil) == "Allow 2 statements in app?")
}
