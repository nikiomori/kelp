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
    #expect(MySQLRun.script(["SELECT 1 -- note"]).hasPrefix("SELECT 1 -- note\n;\n"))
}

/// psql in a container reads the statements on stdin, so none is in the process list or held to an argument's length;
/// each is a quoted string psql runs as it is (`\gexec`), its own commands (`\!`) unread, as `-c` sent them.
@Test func psqlGetsTheStatementsAsQuotedStrings() {
    #expect(
        PostgresRun.script(["BEGIN", #"SELECT 1 \! touch /tmp/x"#])
            == "SELECT $kelp$BEGIN$kelp$ \\gexec\n\\echo \(PostgresRun.marker)\n"
            + #"SELECT $kelp$SELECT 1 \! touch /tmp/x$kelp$ \gexec"# + "\n")
    // A statement that holds the quote's tag, or ends where it would start one, gets another
    #expect(PostgresRun.script(["SELECT '$kelp$'"]) == "SELECT $kelp_$SELECT '$kelp$'$kelp_$ \\gexec\n")
    #expect(PostgresRun.script(["SELECT 1 AS a$kelp"]) == "SELECT $kelp_$SELECT 1 AS a$kelp$kelp_$ \\gexec\n")
}

/// The mysql client's rows keep a row of one empty value (an empty line), and a container that has only `mariadb`
/// (MariaDB 11's images) runs that.
@Test func mysqlsBatchOutputKeepsEmptyRowsAndFindsMariaDB() throws {
    #expect(MySQLRun.section("v\n\nx\n").rows == [[""], ["x"]])
    #expect(MySQLRun.section("").columns.isEmpty)
    let bin = tmp().appendingPathComponent("bin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bin) }
    let mariadb = bin.appendingPathComponent("mariadb")
    try "#!/bin/sh\necho mariadb \"$@\"\n".write(to: mariadb, atomically: true, encoding: .utf8)
    chmod(mariadb.path, 0o755)
    let ran = Process(), out = Pipe()
    ran.executableURL = URL(fileURLWithPath: "/bin/sh")
    ran.arguments = Array(MySQLRun.client.dropFirst()) + ["--batch"]
    ran.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
    ran.standardOutput = out
    try ran.run()
    ran.waitUntilExit()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "mariadb --batch\n")
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
    let path = tmp().appendingPathComponent("app.sqlite3").path
    let queue = try DatabaseQueue(path: path)
    try await queue.write { try $0.execute(sql: "CREATE TABLE t (code TEXT PRIMARY KEY, note TEXT)") }
    try await queue.write { try $0.execute(sql: "CREATE TABLE u (id INTEGER PRIMARY KEY, note TEXT)") }
    try queue.close()
    let schema = try await SQLiteRun(connection: fileConnection(path, .sqlite), off: Slots(1)).schema()
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
    let folder = tmp().path + "/kelp-lib-\(UUID().uuidString)"
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
