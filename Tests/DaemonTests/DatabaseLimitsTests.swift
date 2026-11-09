import Core
import Foundation
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
