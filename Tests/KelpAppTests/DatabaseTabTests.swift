import Core
import Testing

@testable import BuiltinDatabases

/// Edited cells become one UPDATE a row, found by the primary key as read; NULL and quotes are written as SQL.
@Test func editedCellsBecomeUpdatesByPrimaryKey() {
    var edits = DatabaseEdits()
    let rows: [[String?]] = [["1", "paid", nil], ["2", "it's", "x"]]
    edits.set(row: 1, column: 1, to: "o'k", was: "it's")
    edits.set(row: 1, column: 2, to: nil, was: "x")
    edits.set(row: 0, column: 1, to: "paid", was: "paid")   // typed back as it was: no edit
    #expect(edits.count == 2)
    let sql = edits.statements(
        table: "orders", engine: .postgres, columns: ["id", "status", "note"], primary: ["id"], rows: rows)
    #expect(sql == [#"UPDATE "orders" SET "status" = 'o''k', "note" = NULL WHERE "id" = '2'"#])
    #expect(edits.statements(table: "t", engine: .sqlite, columns: ["a"], primary: [], rows: rows) == nil)
    #expect(DatabaseEdits.name("public.my`t", .mysql) == "`public`.`my``t`")
    #expect(DatabaseEdits.literal(#"a\b"#, .mysql) == #"'a\\b'"#)
}

@Test func aDatabaseTabsAddressNamesItsWorkspaceDatabaseAndRun() {
    let uri = DatabaseURI(worktree: "w1", name: "app dev", run: "r9")
    #expect(uri.uri == "db:w1/app%20dev?run=r9")
    #expect(DatabaseURI(uri.uri) == uri)
    #expect(DatabaseURI("db:w1/shop")?.run == nil && DatabaseURI("db:w1") == nil)
}
