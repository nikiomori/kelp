import Core
import Foundation
import Testing

@testable import BuiltinDatabases

// An agent's change put back from the rows Kelp kept of it.

private func result(_ kind: RowChange.Kind, _ rows: [[String?]], before: [[String?]]? = nil) -> QueryResult {
    var result = QueryResult(
        id: "r", columns: ["id", "status", "note"], rows: rows, total: rows.count, changed: rows.count, ms: 0)
    result.change = RowChange(kind: kind, table: "orders", key: ["id"], before: before)
    return result
}

/// A SQLite file with `orders` as an agent found it; `sql` runs on it through sqlite3, as the statements would.
private func run(_ path: String, _ sql: String) throws -> String {
    let sqlite = Process(), out = Pipe()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [path, sql]
    sqlite.standardOutput = out
    try sqlite.run()
    sqlite.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private let listed = "SELECT group_concat(id || ':' || status || ':' || ifnull(note, 'NULL'), ' ') FROM orders"

private func orders() throws -> String {
    let path = NSTemporaryDirectory() + "kelp-undo-\(UUID().uuidString).sqlite"
    _ = try run(
        path,
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT, note TEXT);"
            + "INSERT INTO orders VALUES (10, 'pending', NULL), (20, 'pending', 'it''s'), (30, 'paid', NULL)")
    return path
}

/// An update is undone a row at a time, by its key: only the values it changed go back, NULL as NULL. The rows are
/// read first, and must be as the change left them.
@Test func anUpdateIsUndoneByPuttingItsChangedValuesBack() throws {
    let path = try orders()
    defer { try? FileManager.default.removeItem(atPath: path) }
    _ = try run(path, "UPDATE orders SET status = 'cancelled', note = 'Expired' WHERE status = 'pending'")
    let change = result(
        .update, [["10", "cancelled", "Expired"], ["20", "cancelled", "Expired"]],
        before: [["10", "pending", nil], ["20", "pending", "it's"]])
    #expect(DatabaseUndo.refusal(change) == nil)
    #expect(
        DatabaseUndo.check(change, .sqlite)
            == #"SELECT "id", "status", "note" FROM orders WHERE ("id" = '10') OR ("id" = '20')"#)
    #expect(try run(path, DatabaseUndo.check(change, .sqlite)) == "10|cancelled|Expired\n20|cancelled|Expired")
    #expect(DatabaseUndo.unchanged(change, now: [["20", "cancelled", "Expired"], ["10", "cancelled", "Expired"]]))
    #expect(!DatabaseUndo.unchanged(change, now: [["10", "paid", "Expired"], ["20", "cancelled", "Expired"]]))
    #expect(!DatabaseUndo.unchanged(change, now: [["10", "cancelled", "Expired"]]))   // one is gone
    let statements = DatabaseUndo.statements(change, .sqlite)
    #expect(
        statements == [
            #"UPDATE orders SET "status" = 'pending', "note" = NULL WHERE "id" = '10'"#,
            #"UPDATE orders SET "status" = 'pending', "note" = 'it''s' WHERE "id" = '20'"#
        ])
    _ = try run(path, statements.joined(separator: ";"))
    #expect(try run(path, listed) == "10:pending:NULL 20:pending:it's 30:paid:NULL")
}

/// A delete's rows are inserted again as they were, an insert's deleted by their key.
@Test func aDeleteAndAnInsertAreUndone() throws {
    let path = try orders()
    defer { try? FileManager.default.removeItem(atPath: path) }
    _ = try run(path, "DELETE FROM orders WHERE id < 30")
    let deleted = result(.delete, [["10", "pending", nil], ["20", "pending", "it's"]])
    #expect(DatabaseUndo.unchanged(deleted, now: []) && !DatabaseUndo.unchanged(deleted, now: [["10", "x", nil]]))
    _ = try run(path, DatabaseUndo.statements(deleted, .sqlite).joined(separator: ";"))
    #expect(try run(path, listed) == "10:pending:NULL 20:pending:it's 30:paid:NULL")

    _ = try run(path, "INSERT INTO orders VALUES (40, 'new', NULL)")
    let added = result(.insert, [["40", "new", nil]])
    #expect(DatabaseUndo.unchanged(added, now: [["40", "new", nil]]))
    #expect(DatabaseUndo.statements(added, .sqlite) == [#"DELETE FROM orders WHERE "id" = '40'"#])
    _ = try run(path, DatabaseUndo.statements(added, .sqlite).joined(separator: ";"))
    #expect(try run(path, listed) == "10:pending:NULL 20:pending:it's 30:paid:NULL")
}

/// Nothing is put back from rows Kelp doesn't hold whole: none kept, a change it can't tell, no key, an update
/// without its rows as they were.
@Test func aChangeKelpDidntKeepWholeIsntUndone() {
    #expect(DatabaseUndo.refusal(nil) != nil)
    var none = result(.update, [["10", "x", nil]], before: [["10", "y", nil]])
    none.change = nil
    #expect(DatabaseUndo.refusal(none) != nil)
    var keyless = result(.delete, [["10", "x", nil]])
    keyless.change?.key = []
    #expect(DatabaseUndo.refusal(keyless) != nil)
    #expect(DatabaseUndo.refusal(result(.update, [["10", "x", nil]])) != nil)
    #expect(DatabaseUndo.refusal(result(.delete, [["10", "x", nil]])) == nil)
}

/// The table marks the rows of its latest change when an agent made it: once the user has changed the table since (an
/// undo), the marks would say the agent's values are there, so there are none.
@MainActor @Test func rowsAreMarkedOnlyWhileTheAgentsChangeIsTheLatest() {
    func run(_ id: String, by session: String?, _ sql: String, changed: Int? = 1) -> DatabaseRun {
        DatabaseRun(id: id, database: "shop", sql: sql, session: session, at: Date(), state: .done, changed: changed)
    }
    let agents = run("a", by: "s1", "UPDATE orders SET status = 'x'")
    let read = run("r", by: "s1", "SELECT * FROM orders", changed: nil)
    #expect(DatabaseTab.lastAgentChange([read, agents], to: "orders", in: "shop")?.id == "a")
    let undo = run("u", by: nil, "UPDATE orders SET \"status\" = 'pending' WHERE \"id\" = '1'")
    #expect(DatabaseTab.lastAgentChange([undo, agents], to: "orders", in: "shop") == nil)
    #expect(DatabaseTab.lastAgentChange([undo, agents], to: "users", in: "shop") == nil)
    #expect(DatabaseTab.lastAgentChange([agents], to: "orders", in: "other") == nil)
}
