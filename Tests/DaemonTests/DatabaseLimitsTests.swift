import Core
import Foundation
import GRDB
import Testing
import os

@testable import Daemon

/// A server that stops answering (a network gone mid-read) doesn't hold a call past its time: the connection is
/// closed and the call says so; one that answers in time is answered.
@Test func aWireCallThatGetsNoAnswerEndsAtItsTime() async throws {
    let db = DatabaseInfo(name: "app", engine: .postgres, host: "db.example.com")
    let closed = OSAllocatedUnfairLock(initialState: false)
    let started = Date()
    do {
        _ = try await DatabaseWire.within(0.2, db, close: { closed.withLock { $0 = true } }) {
            try await Task.sleep(for: .seconds(60))
            return 1
        }
        Issue.record("answered")
    } catch let failure as DatabaseFailure {
        #expect(failure.message.contains("No answer from app"))
    }
    #expect(closed.withLock { $0 } && Date().timeIntervalSince(started) < 30)
    #expect(try await DatabaseWire.within(30, db, close: {}) { 7 } == 7)
}

/// What kelpd keeps of a result (and sends an agent) stays small whatever the cells hold: a long cell is cut, rows
/// past a megabyte are left out, and the total still says how many there were.
@Test func aKeptResultIsCutToItsSize() {
    let long = String(repeating: "é", count: 20_000)
    let wide = QueryResult(id: "r", columns: ["body"], rows: [[long], [nil]], total: 2, ms: 0)
    let cut = Databases.trimmed(wide)
    #expect(cut.rows.count == 2 && cut.rows[1] == [nil] && cut.total == 2)
    #expect(cut.rows[0][0]?.hasSuffix("…") == true && (cut.rows[0][0]?.utf8.count ?? 0) <= Databases.keptCell + 3)
    let many = QueryResult(
        id: "r", columns: ["body"], rows: Array(repeating: [String(repeating: "x", count: 10_000)], count: 1000),
        total: 5000, ms: 0)
    let kept = Databases.trimmed(many)
    #expect(kept.rows.count == Databases.keptBytes / 10_000 && kept.total == 5000)
}

/// A change to a SQLite file stops at its time as a read does, and is undone: the tab isn't told it failed while it
/// lands later.
@Test func aSQLiteChangeStopsAtItsTimeAndIsUndone() throws {
    let path = NSTemporaryDirectory() + "kelp-slow-\(UUID().uuidString).sqlite"
    let queue = try SQLiteRun.open(path, readOnly: false)
    #expect(throws: DatabaseFailure.failed("It took more than 0 s.")) {
        try SQLiteRun.stopped(queue, after: 0.3) {
            try queue.inDatabase { db in
                try db.execute(
                    sql: "CREATE TABLE big AS WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r) "
                        + "SELECT x FROM r")
            }
        }
    }
    #expect(try queue.read { try $0.tableExists("big") } == false)
}
