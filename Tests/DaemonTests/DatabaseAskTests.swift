import Agents
import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

// What becomes of an agent's change while the user is asked: its program ending, a second ask, access changing.

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])

/// `orders` with three pending rows and `users` with one, in the project's db/ folder.
private func askDB(in root: String) throws -> String {
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

/// The agent's command is cut off (Esc, its tool's time limit) while the user is asked: the question goes, and an Allow
/// given late changes nothing, so a command run again doesn't change it twice.
@Test func aChangeWhoseCommandEndedIsNeverRun() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try askDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let program = Process()
    program.executableURL = URL(fileURLWithPath: "/bin/sleep")
    program.arguments = ["60"]
    try program.run()
    let update = DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'paid'")
    let asked = Task {
        try await w.d.workspaces.databases.query(update, origin: agent.id, asker: program.processIdentifier)
    }
    #expect(try await waitFor { try summary(w, agent.id).hasPrefix("Allow changing") })
    program.terminate()
    do {
        _ = try await asked.value
        Issue.record("a change whose command ended ran")
    } catch { #expect("\(error)".contains("ended before an answer")) }
    #expect(try await waitFor { try !summary(w, agent.id).hasPrefix("Allow") })
    #expect(try await !w.c.call(SessionChoose(id: agent.id, answer: "allow")))   // nothing left to allow
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'paid'") == 0)
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first?.state == .denied)
}

/// Two changes asked at once (parallel tool calls): each waits its turn on the row, oldest first, named by its
/// table, and neither is dropped as unanswered.
@Test func twoChangesAskedAtOnceWaitTheirTurn() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try askDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    let orders = Task {
        try await dbs.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'paid'"),
            origin: agent.id)
    }
    #expect(try await waitFor { try summary(w, agent.id) == "Allow changing 3 rows of orders in shop?" })
    let users = Task {
        try await dbs.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "DELETE FROM users"), origin: agent.id)
    }
    #expect(
        try await waitFor {
            try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.filter { $0.state == .asks }.count == 2
        })
    #expect(try summary(w, agent.id) == "Allow changing 3 rows of orders in shop?")   // the oldest is asked first
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: try summary(w, agent.id))))
    #expect(try await orders.value.changed == 3)
    #expect(try await waitFor { try summary(w, agent.id) == "Allow changing 1 row of users in shop?" })
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "deny", question: try summary(w, agent.id))))
    do {
        _ = try await users.value
        Issue.record("a denied change ran")
    } catch { #expect("\(error)".contains("denied")) }
    #expect(try count(path, "SELECT count(*) FROM users") == 1)
}

/// Two identical prompts are distinct waits. A phone's outstanding answer cannot be used on the second one.
@Test func aPhoneAnswersOnlyTheDisplayedKelpWait() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let workspace = try await firstWorkspace(w)
    let agent = try await w.c.call(SessionCreate(worktreeId: workspace.id, agent: "bot"))
    let session = try #require(w.d.sessions.existing(agent.id)), permissions = w.d.sessions.permissions
    let question = "Allow the change?"
    func shown() -> String? { permissions.questionId(session, for: question)?.uuidString }
    func decide(_ id: String, _ answer: String) async throws -> Bool {
        try await w.c.call(SessionChoose(id: agent.id, answer: answer, question: question, questionId: id))
    }
    let first = Task { await permissions.waitForKelp(session, question: question, within: 5) }
    try #require(try await waitFor { shown() != nil })
    let firstID = try #require(shown())
    let second = Task { await permissions.waitForKelp(session, question: question, within: 5) }
    try #require(try await waitFor { session.state.withLock { $0.kelpQuestions.count == 2 } })
    #expect(try await decide(firstID, "deny"))
    #expect(await first.value == "deny")
    let secondID = try #require(shown())
    #expect(firstID != secondID)
    #expect(try await !decide(firstID, "allow"))
    #expect(try await decide(secondID, "deny"))
    #expect(await second.value == "deny")
}

/// Two changes asked at once: what shows a change to allow shows the one the row asks (the oldest), and an answer
/// given for one run's change (the card, the panel, the tab) goes to that change, never to the other one.
@Test func anAnswerForOneRunGoesToThatChange() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try askDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let dbs = w.d.workspaces.databases
    func ask(_ sql: String) -> Task<QueryResult, Error> {
        Task { try await dbs.query(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: sql), origin: agent.id) }
    }
    let orders = ask("UPDATE orders SET status = 'paid'")
    #expect(try await waitFor { try summary(w, agent.id) == "Allow changing 3 rows of orders in shop?" })
    let users = ask("DELETE FROM users")
    func asking() async throws -> [DatabaseRun] {
        try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.filter { $0.state == .asks }
    }
    #expect(try await waitFor { try await asking().count == 2 })
    let runs = try await asking()
    #expect(runs.asked(by: agent.id)?.sql == "UPDATE orders SET status = 'paid'")
    let newer = try #require(runs.first { $0.sql == "DELETE FROM users" })
    let question = try summary(w, agent.id)
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "deny", question: question, run: newer.id)))
    do {
        _ = try await users.value
        Issue.record("a denied change ran")
    } catch { #expect("\(error)".contains("denied")) }
    #expect(try await asking().map(\.sql) == ["UPDATE orders SET status = 'paid'"])
    #expect(try await !w.c.call(SessionChoose(id: agent.id, answer: "allow", run: newer.id)))   // answered already
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: question)))
    #expect(try await orders.value.changed == 3)
    #expect(try count(path, "SELECT count(*) FROM users") == 1)
}

/// The user makes the database read-only for agents while its change is asked: an Allow given before they noticed
/// doesn't run it.
@Test func aDatabaseMadeReadOnlyWhileAskedIsntChanged() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try askDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let asked = Task {
        try await w.d.workspaces.databases.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'paid'"),
            origin: agent.id)
    }
    #expect(try await waitFor { try summary(w, agent.id).hasPrefix("Allow changing") })
    var shop = try #require(try await w.c.call(DatabaseList(worktreeId: wt.id)).first)
    shop.access = .read
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: shop))
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: try summary(w, agent.id))))
    await expectRefusal(says: "became read-only for agents while it was asked") { try await asked.value }
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'paid'") == 0)
}

@Test func aChangesQuestionNamesItsTable() {
    func asked(_ sql: String) -> String { Databases.question(sql, database: "app", changed: 2) }
    #expect(asked("UPDATE orders SET a = 1") == "Allow changing 2 rows of orders in app?")
    #expect(asked("-- fix\ndelete from \"Order Items\" where id > 3") == "Allow changing 2 rows of Order Items in app?")
    #expect(asked("INSERT OR REPLACE INTO public.users VALUES (1)") == "Allow changing 2 rows of public.users in app?")
    #expect(asked("INSERT IGNORE INTO `t`(a) VALUES (1)") == "Allow changing 2 rows of t in app?")
    #expect(asked("UPDATE ONLY items SET a = 1") == "Allow changing 2 rows of items in app?")
    let ddl = Databases.question("CREATE TABLE t (a int)", database: "app", changed: 0)
    #expect(ddl == "Allow CREATE TABLE t (a int) in app?")
    // A change inside a query counts what it returns, not its rows: the question doesn't hold it to a number
    for hidden in ["WITH d AS (DELETE FROM big) SELECT 1", "EXPLAIN ANALYZE UPDATE big SET a = 1", "SELECT purge()"] {
        #expect(asked(hidden) == "Allow \(hidden) in app? Kelp can’t count the rows it changes.")
    }
    // A long one says it's cut, and where the rest is: what's allowed from the Dock isn't only its first line
    let body = (1...20).map { "  PERFORM step\($0);" }.joined(separator: "\n")
    let function = Databases.question(
        "CREATE FUNCTION tidy() RETURNS void AS $$\nBEGIN\n\(body)\nEND $$ LANGUAGE plpgsql", database: "app",
        changed: nil)
    #expect(function.hasPrefix("Allow CREATE FUNCTION tidy() RETURNS void AS $$ BEGIN PERFORM step1;"))
    #expect(function.hasSuffix("(23 lines, whole in Databases) in app?"))
}

/// What makes an asked change worth a second look is read from its text, and only these kinds have a line: no WHERE, a
/// DROP or TRUNCATE, a dropped column, a row change Undo This Change couldn't put back. A plain change has none.
@Test func aChangesRiskIsReadFromItsText() {
    let undoable = RowChange(kind: .delete, table: "orders", key: ["id"])
    let rows: [(String, RowChange?, ChangeRisk?, String?)] = [
        ("UPDATE orders SET status = 'archived'", undoable, ChangeRisk(kind: .noWhere, table: "orders"), nil),
        ("delete from orders -- where id = 1", undoable, ChangeRisk(kind: .noWhere, table: "orders"), nil),
        ("UPDATE orders SET note = 'where'", undoable, ChangeRisk(kind: .noWhere, table: "orders"), nil),
        ("DELETE FROM orders WHERE id = 1", undoable, nil, nil),
        ("DELETE FROM orders WHERE id IN (SELECT id FROM old)", undoable, nil, nil),
        (   // a WHERE or LIMIT in a subquery isn't the statement's own
            "UPDATE orders SET total = (SELECT max(t) FROM prices WHERE id = 1 LIMIT 1)", undoable,
            ChangeRisk(kind: .noWhere, table: "orders"), nil
        ),
        ("DELETE FROM orders WHERE id = 1", nil, ChangeRisk(kind: .noUndo, table: "orders"), nil),
        ("INSERT INTO orders VALUES (4, 'new')", RowChange(kind: .insert, table: "orders", key: ["id"]), nil, nil),
        (
            "ALTER TABLE orders DROP COLUMN note", nil, ChangeRisk(kind: .dropColumn, table: "orders", column: "note"),
            "SELECT count(note) FROM orders"
        ),
        ("ALTER TABLE orders DROP CONSTRAINT orders_pkey", nil, nil, nil),
        (
            #"DROP TABLE IF EXISTS "Order Items""#, nil, ChangeRisk(kind: .drop, table: #""Order Items""#),
            #"SELECT count(*) FROM "Order Items""#
        ),
        ("DROP INDEX CONCURRENTLY orders_idx", nil, ChangeRisk(kind: .drop, table: "orders_idx"), nil),
        ("TRUNCATE TABLE orders", nil, ChangeRisk(kind: .truncate, table: "orders"), "SELECT count(*) FROM orders"),
        ("CREATE TABLE t (a int)", nil, nil, nil)
    ]
    for (sql, change, risk, counting) in rows {
        let found = Databases.risk(sql, change: change)
        #expect(found?.risk == risk && found?.counting == counting, "\(sql)")
    }
}

/// An agent's DROP COLUMN asked about: its trial is kept with how many values of the column go.
@Test func anAskedDropCountsWhatGoes() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try askDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let asked = Task {
        try await w.d.workspaces.databases.query(
            DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "ALTER TABLE orders DROP COLUMN status"),
            origin: agent.id)
    }
    #expect(try await waitFor { try summary(w, agent.id).hasPrefix("Allow ALTER TABLE") })
    let run = try #require(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first)
    let kept = try await w.c.call(DatabaseResultRead(worktreeId: wt.id, id: run.id))
    #expect(kept?.risk == ChangeRisk(kind: .dropColumn, table: "orders", column: "status", values: 3))
    #expect(run.changed == nil)   // a DDL's 0 isn't a count of rows that would change
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "deny", question: try summary(w, agent.id))))
    _ = try? await asked.value
    #expect(try count(path, "SELECT count(*) FROM orders") == 3)
}
