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
    await #expect(throws: RPCError.self) { try await asked.value }
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
}
