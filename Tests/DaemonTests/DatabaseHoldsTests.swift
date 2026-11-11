import Agents
import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

// What a database call holds to: the rows the user allowed, the size Kelp reads, the time a server may take to greet,
// a check that doesn't hold the others' dots, a copy that failed leaving nothing.

private let bot = AgentManifest(id: "bot", name: "Bot", command: "/bin/sh", args: ["-c", "cat"])

/// `orders` with three pending rows, in the project's db/ folder.
/// A file's database, for its engine called directly.
func fileConnection(_ path: String, _ engine: DatabaseInfo.Engine) -> DatabaseConnection {
    DatabaseConnection(database: DatabaseInfo(name: "shop", engine: engine, path: path))
}

private func ordersDB(in root: String) throws -> String {
    let dir = (root as NSString).appendingPathComponent("db")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("shop.sqlite3")
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)")
        try db.execute(sql: "INSERT INTO orders VALUES (1, 'pending'), (2, 'pending'), (3, 'pending')")
    }
    try queue.close()
    return path
}

private func count(_ path: String, _ sql: String) throws -> Int {
    try DatabaseQueue(path: path).read { try Int.fetchOne($0, sql: sql) ?? -1 }
}

private func summary(_ w: World, _ id: String) throws -> String { try w.d.store.session(id)?.summary ?? "" }

/// The user allows "3 rows"; a fourth row comes in before the Allow: nothing is changed, and the agent hears why.
@Test func aChangeAllowedForSomeRowsDoesntChangeMore() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try ordersDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let pay = DatabaseQuery(
        worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'paid' WHERE status = 'pending'")
    let asked = Task { try await w.d.workspaces.databases.query(pay, origin: agent.id) }
    #expect(try await waitFor { try summary(w, agent.id) == "Allow changing 3 rows of orders in shop?" })
    try await DatabaseQueue(path: path).write { try $0.execute(sql: "INSERT INTO orders VALUES (4, 'pending')") }
    #expect(try await w.c.call(SessionChoose(id: agent.id, answer: "allow", question: try summary(w, agent.id))))
    do {
        _ = try await asked.value
        Issue.record("a change of 4 rows ran on an Allow for 3")
    } catch { #expect("\(error)".contains("not the 3 rows the user allowed")) }
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'paid'") == 0)
}

/// Nobody answers: what the question's time running out does (`PermissionWaits` answers it with nothing), done now
/// instead of in ten minutes. It's said as unanswered, and nothing changes.
@Test func aChangeNobodyAnswersIsntRun() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try ordersDB(in: wt.path)
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let pay = DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'paid'")
    let asked = Task { try await w.d.workspaces.databases.query(pay, origin: agent.id) }
    #expect(try await waitFor { try summary(w, agent.id).hasPrefix("Allow changing") })
    #expect(w.d.sessions.permissions.answerKelp(agent.id, question: nil, nil))
    do {
        _ = try await asked.value
        Issue.record("an unanswered change ran")
    } catch { #expect("\(error)".contains("Nobody answered")) }
    #expect(try count(path, "SELECT count(*) FROM orders WHERE status = 'paid'") == 0)
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first?.state == .denied)
}

/// A file the user can't write: an agent's change isn't asked (it couldn't run), and says why, as a run.
@Test func aChangeToAReadOnlyFileSaysSo() async throws {
    let w = try await world(agents: [bot])
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let path = try ordersDB(in: wt.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "bot"))
    let pay = DatabaseQuery(worktreeId: wt.id, database: "shop", sql: "UPDATE orders SET status = 'paid'")
    do {
        _ = try await w.d.workspaces.databases.query(pay, origin: agent.id)
        Issue.record("a change to a read-only file ran")
    } catch { #expect("\(error)".contains("takes no changes")) }
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs.first?.state == .failed)
}

/// An answer past what Kelp reads (32 MB) is refused whole, never sent as fewer rows; kept rows stop growing there.
@Test func anAnswerTooBigToReadIsRefused() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    _ = try ordersDB(in: wt.path)
    let big = """
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 900)
        SELECT printf('%.*c', 40000, 'x') FROM n
        """
    await #expect(throws: RPCError.self) {
        try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "shop", sql: big))
    }
    var rows = DatabaseRows()
    for _ in 0..<900 { rows.add(columns: ["a"], [String(repeating: "x", count: 40_000)]) }
    #expect(rows.total == 900 && rows.bytes > DatabaseEngines.outputLimit)
    #expect(rows.rows.count * 40_000 <= DatabaseEngines.outputLimit)
}

/// What's kept of a result past 1 MB of cells is marked cut: a larger --limit wouldn't give more.
@Test func aResultCutForItsSizeSaysSo() {
    let cell = String(repeating: "x", count: Databases.keptCell)
    let rows = Array(repeating: [Optional(cell)], count: 100)
    let kept = Databases.trimmed(QueryResult(id: "r", columns: ["a"], rows: rows, total: 100, ms: 1))
    #expect(kept.cut == true && kept.rows.count < 100)
    let small = Databases.trimmed(QueryResult(id: "r", columns: ["a"], rows: [["x"]], total: 1, ms: 1))
    #expect(small.cut == nil)
}

/// A copy for a branch that fails half way (here: the project's file is SQLite only by its first bytes) leaves no
/// file behind, so the next one isn't refused as made already.
@Test func aFailedCopyLeavesNothing() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let main = try await firstWorkspace(w)
    let path = try ordersDB(in: main.path)
    var broken = Data("SQLite format 3\0".utf8)
    broken.append(Data(repeating: 0xA5, count: 8192))
    try broken.write(to: URL(fileURLWithPath: path))
    let branch = try await workspace(w, "fix/copy")
    #expect(try await w.c.call(DatabaseList(worktreeId: branch.id)).first?.path == path)
    for _ in 0..<2 {
        do {
            _ = try await w.c.call(DatabaseCopy(worktreeId: branch.id, database: "shop"))
            Issue.record("a copy of a file that can't be read was made")
        } catch { #expect(!"\(error)".contains("There's a copy already"), "\(error)") }
        #expect(!FileManager.default.fileExists(atPath: branch.path + "/db/shop.sqlite3"))
    }
}

/// The schema's row counts have a time of their own: past it a table shows no count, but its columns all the same.
@Test func aSQLiteSchemaCountsOnlyWhileItHasTime() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try ordersDB(in: dir)
    let c = fileConnection(path, .sqlite)
    let counted = try await SQLiteRun(c: c, off: Slots(1)).schema()
    #expect(counted.tables.first?.rows == 3)
    let late = try await SQLiteRun(c: c, off: Slots(1), counting: 0).schema()
    #expect(late.tables.first?.rows == nil && late.tables.first?.columns.count == 2)
}

/// A database whose check doesn't end is said as such at its time; the answer doesn't wait for it.
@Test func aHealthCheckThatDoesntEndIsSaidLate() async {
    let (never, holder) = AsyncStream<Int>.makeStream()
    let started = Date()
    let said = await Databases.answer(within: 0.2, or: "late") {
        for await _ in never {}   // never ends: its continuation is held below
        _ = holder
        return "answered"
    }
    #expect(said == "late" && Date().timeIntervalSince(started) < 5)
    #expect(await Databases.answer(within: 5, or: "late") { "answered" } == "answered")
}

/// Something takes the TCP connection and never greets (a forward with no server behind it): the MySQL call ends at
/// its handshake's time, not the client's 16 minutes.
@Test func aMySQLServerThatNeverGreetsEndsAtItsTime() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    #expect(listener >= 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) == 0 }
    }
    #expect(bound && listen(listener, 4) == 0)   // the kernel takes the connection; nobody ever answers it
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
    }
    let port = Int(UInt16(bigEndian: address.sin_port))
    let db = DatabaseInfo(name: "silent", engine: .mysql, host: "127.0.0.1", port: port, user: "root")
    let started = Date()
    do {
        _ = try await MySQLWire.open(DatabaseConnection(database: db), handshake: 0.5)
        Issue.record("a server that never greeted was connected")
    } catch { #expect("\(error)".contains("No answer from silent")) }
    #expect(Date().timeIntervalSince(started) < 5)
}
