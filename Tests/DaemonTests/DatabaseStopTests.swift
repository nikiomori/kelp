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
