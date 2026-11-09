import Core
import Foundation
import GRDB
import TestSupport
import Testing

@testable import Daemon

// What an agent meets of the databases besides a question: which chats get the skill, a statement's last comment.

/// A branch's chat gets the database skill for the project's SQLite file it lists, an untracked one in the project's
/// folder included; a project with none gets none.
@Test func aBranchChatGetsTheSkillForTheProjectsDatabase() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let main = try await firstWorkspace(w)
    let branch = try await workspace(w, "fix/orders")
    #expect(!w.d.sessions.setup.hasDatabases(worktreeId: branch.id))
    let dir = (main.path as NSString).appendingPathComponent("db")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: (dir as NSString).appendingPathComponent("shop.sqlite3"))
    try await queue.write { try $0.execute(sql: "CREATE TABLE t (a)") }
    try queue.close()
    #expect(try await w.c.call(DatabaseList(worktreeId: branch.id)).map(\.name) == ["shop"])
    #expect(w.d.sessions.setup.hasDatabases(worktreeId: branch.id))
}

/// What Kelp puts after an agent's statement starts a line of its own: a trailing `-- comment` doesn't swallow it.
@Test func whatKelpAddsToAStatementOutlivesItsLastComment() {
    #expect(SQLText.returning("UPDATE t SET a = 1 -- fix") == "UPDATE t SET a = 1 -- fix\nRETURNING *")
    #expect(MySQLRun.counted("DELETE FROM t # old").hasPrefix("DELETE FROM t # old\n;"))
}

/// The built-ins that run a query given as text are refused to agents as what they'd run would be: a text check can't
/// read a query glued together inside one.
@Test func aQueryRunFromTextIsntAWayPastTheCheck() {
    for sql in [
        "SELECT query_to_xml('SELECT pg_read' || '_file(''/etc/passwd'')', true, true, '')",
        "SELECT * FROM ts_stat('SELECT to_tsvector(pg_read' || '_file(''x''))')", "SELECT pg_ls_logdir()"
    ] {
        #expect(SQLText.pastTheDatabase(sql, .postgres) != nil, "\(sql)")
    }
    #expect(SQLText.pastTheDatabase("SELECT xmlelement(name a, 'x')", .postgres) == nil)
}

/// SQLite's INTEGER PRIMARY KEY is the rowid: the schema doesn't call it nullable, as an agent would then guard for it.
@Test func aSQLiteRowidKeyIsntNullable() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let queue = try DatabaseQueue(path: (wt.path as NSString).appendingPathComponent("app.sqlite3"))
    try await queue.write { try $0.execute(sql: "CREATE TABLE t (code TEXT PRIMARY KEY, note TEXT)") }
    try await queue.write { try $0.execute(sql: "CREATE TABLE u (id INTEGER PRIMARY KEY, note TEXT)") }
    try queue.close()
    let schema = try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "app"))
    let nullable = Dictionary(uniqueKeysWithValues: schema.tables.map { ($0.name, $0.columns.map(\.nullable)) })
    #expect(nullable["u"] == [false, true])
    #expect(nullable["t"] == [true, true])   // a TEXT key takes NULL in SQLite, unless NOT NULL says otherwise
}

/// One of All My Projects used in a project, then removed from it: the project lists it no more, its agents can't reach
/// it, and All My Projects still has it, as it was.
@Test func removingAUsedDatabaseFromAProjectKeepsItInTheLibrary() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let folder = NSTemporaryDirectory() + "kelp-lib-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let path = (folder as NSString).appendingPathComponent("gis.sqlite3")
    let queue = try DatabaseQueue(path: path)
    try await queue.write { try $0.execute(sql: "CREATE TABLE t (a)") }
    try queue.close()
    let gis = DatabaseInfo(name: "gis", engine: .sqlite, path: path, access: .read)
    _ = try await w.c.call(DatabaseSave(worktreeId: wt.id, database: gis, library: true))
    _ = try await w.c.call(DatabaseUse(worktreeId: wt.id, name: "gis"))
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).map(\.name) == ["gis"])

    _ = try await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "gis"))
    #expect(try await w.c.call(DatabaseList(worktreeId: wt.id)).isEmpty)
    #expect(try await w.c.call(DatabaseActivity(worktreeId: wt.id)).library?.map(\.name) == ["gis"])
}
