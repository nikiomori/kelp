import Core
import Foundation
import GRDB
import TestSupport
import Testing
import os

@testable import Daemon

/// The user's Stop ends a statement in SQLite itself, not just the wait for it: the call says Stopped soon after,
/// and the run is kept as stopped.
@Test func aStatementTheUserStopsEndsInSQLite() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    try slowDB(in: wt.path)
    let endless =
        "WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r) SELECT count(*) FROM r"
    let running = Task {
        try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "slow", sql: endless, cancelId: "s1"))
    }
    let started = Date()
    #expect(try await waitFor { w.d.workspaces.databases.stops.withLock { $0["s1"] != nil } })
    _ = try await w.c.call(DatabaseCancel(id: "s1"))
    await #expect { try await running.value } throws: { ($0 as? RPCError)?.message == DatabaseCancel.stopped }
    #expect(Date().timeIntervalSince(started) < 10)
    let runs = try await w.c.call(DatabaseActivity(worktreeId: wt.id)).runs
    #expect(runs.first?.state == .failed && runs.first?.error == DatabaseCancel.stopped)
}

private func slowDB(in root: String) throws {
    try FileManager.default.createDirectory(atPath: root + "/db", withIntermediateDirectories: true)
    let queue = try DatabaseQueue(path: root + "/db/slow.sqlite3")
    try queue.write { try $0.execute(sql: "CREATE TABLE t (x INTEGER)") }
    try queue.close()
}

/// A Stop that comes after a change's run began but before SQLite ran its statement (where an interrupt does nothing)
/// still keeps the change out of the file, in a transaction and on its own.
@Test func aChangeStoppedJustBeforeItRunsIsNotKept() throws {
    let root = tmp().path
    try slowDB(in: root)
    let path = root + "/db/slow.sqlite3"
    let changes: [@Sendable (Database) throws -> Void] = [
        { db in
            try db.inTransaction {
                try db.execute(sql: "INSERT INTO t VALUES (1)")
                return .commit
            }
        },
        { try $0.execute(sql: "INSERT INTO t VALUES (2)") }
    ]
    for change in changes {
        let stop = DatabaseStop()
        #expect(throws: (any Error).self) {
            try DatabaseStop.$current.withValue(stop) {
                let queue = try SQLiteRun.open(path, readOnly: false)
                try SQLiteRun.stopped(queue, after: 60) {
                    stop.stop()
                    try queue.inDatabase(change)
                }
            }
        }
    }
    #expect(try DatabaseQueue(path: path).read { try Int.fetchOne($0, sql: "SELECT count(*) FROM t") } == 0)
}

/// A Stop closes a server's connection, which ends a call waiting on it; and it ends a client program at once.
@Test func aStopClosesTheConnectionAndEndsTheClient() async throws {
    let db = DatabaseInfo(name: "app", engine: .postgres, host: "db.example.com")
    let stop = DatabaseStop(), (closed, closing) = AsyncStream<Void>.makeStream()
    let call = Task {
        try await DatabaseStop.$current.withValue(stop) {
            try await DatabaseWire.within(60, db, close: { closing.finish() }) {
                for await _ in closed {}   // until the connection closes
                throw DatabaseFailure.failed("closed")
            }
        }
    }
    stop.stop()
    await #expect(throws: DatabaseFailure.failed("closed")) { try await call.value }

    let program = DatabaseStop(), started = Date()
    let sleeping = Task.detached {
        try DatabaseStop.$current.withValue(program) {
            try DatabaseStop.program(["/bin/sleep", "30"], env: [:], stdin: Data(), timeLimit: 60)
        }
    }
    let mine = getpid()
    #expect(try await waitFor { Subprocess.tree(mine).contains { Subprocess.arguments($0) == ["/bin/sleep", "30"] } })
    program.stop()
    #expect(try await sleeping.value.status != 0 && Date().timeIntervalSince(started) < 10)
}

/// Ending docker's client leaves psql running in the container, so a Stop also ends psql's session on the server, from
/// a second psql that finds it by the name it connected with.
@Test func aStopOfPsqlInAContainerEndsItsSessionOnTheServer() async throws {
    let said = tmp().path + "/said"
    let psql = [
        "/bin/sh", "-c",
        "case \"$*\" in *pg_terminate_backend*) echo \"$PGAPPNAME $*\" > \(said) ;; *) exec /bin/sleep 31 ;; esac",
        "psql"
    ]
    let stop = DatabaseStop()
    let running = Task.detached {
        try DatabaseStop.$current.withValue(stop) {
            try PostgresRun.program(psql, ["-c", "SELECT 1"], password: nil, stdin: Data(), timeout: 60)
        }
    }
    let mine = getpid()
    #expect(try await waitFor { Subprocess.tree(mine).contains { Subprocess.arguments($0) == ["/bin/sleep", "31"] } })
    stop.stop()
    #expect(try await running.value.status != 0)
    #expect(try await waitFor { FileManager.default.fileExists(atPath: said) })
    let words = try String(contentsOfFile: said, encoding: .utf8).split(separator: " ", maxSplits: 1)
    // the second psql ends the session named as the first one connected
    #expect(words.first?.hasPrefix("kelp/") == true && words.last?.contains("'\(words.first ?? "")'") == true)
}

/// mysql in a container goes on after a Stop ends docker's client, so the stopped call says so, not "Stopped."
@Test func aStoppedMySQLInAContainerSaysItMayGoOn() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let dbs = w.d.workspaces.databases
    let running = Task {
        try await dbs.stoppable("m1") {
            let out = try MySQLRun.program(["/bin/sleep", "32"], env: [:], script: "", timeout: 60)
            if out.status != 0 { throw DatabaseFailure.failed("mysql ended") }
        }
    }
    let mine = getpid()
    #expect(try await waitFor { Subprocess.tree(mine).contains { Subprocess.arguments($0) == ["/bin/sleep", "32"] } })
    dbs.cancel("m1")
    await #expect { try await running.value } throws: { ($0 as? RPCError)?.message == MySQLRun.leftRunning }
}
