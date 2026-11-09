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

/// Saving a table's edits: deletes and updates found by the key, new rows inserted with what was typed in them.
@Test func editsBecomeDeletesUpdatesAndInserts() {
    var edits = DatabaseEdits()
    let rows: [[String?]] = [["1", "a"], ["2", "b"]]
    edits.toggleDeleted(1)
    edits.set(row: 0, column: 1, to: "z", was: "a")
    edits.add([nil, "new"])
    edits.add([nil, nil])   // nothing typed: no statement
    #expect(edits.count == 4)
    let sql = edits.statements(table: "t", engine: .postgres, columns: ["id", "v"], primary: ["id"], rows: rows)
    #expect(
        sql == [
            #"DELETE FROM "t" WHERE "id" = '2'"#, #"UPDATE "t" SET "v" = 'z' WHERE "id" = '1'"#,
            #"INSERT INTO "t" ("v") VALUES ('new')"#
        ])
    // A table without a key takes new rows only.
    var only = DatabaseEdits()
    only.add(["x"])
    #expect(
        only.statements(table: "t", engine: .mysql, columns: ["v"], primary: [], rows: []) == [
            "INSERT INTO `t` (`v`) VALUES ('x')"
        ])
}

/// Copy as: each format as the tool it's for reads it.
@Test func rowsCopyAsEachFormat() {
    let columns = ["id", "note", "meta"]
    let rows: [[String?]] = [["1", "a,b", #"{"k":1}"#], ["2", nil, "x"]]
    #expect(ResultText.csv(columns, rows) == "id,note,meta\n1,\"a,b\",\"{\"\"k\"\":1}\"\n2,,x\n")
    #expect(
        ResultText.markdown(columns, [["1", "a|b", nil]])
            == "| id | note | meta |\n| --- | --- | --- |\n| 1 | a\\|b | NULL |")
    let json = ResultText.json(columns, rows)
    #expect(json.contains(#""id" : 1"#) && json.contains(#""note" : null"#) && json.contains(#""k" : 1"#))
    #expect(ResultText.insert(["id"], [["1"]], table: "t", engine: .sqlite) == #"INSERT INTO "t" ("id") VALUES ('1');"#)
    #expect(ResultText.condition("note", nil, equal: true, engine: .postgres) == #""note" IS NULL"#)
    #expect(ResultText.condition("s", "it's", equal: false, engine: .mysql) == "`s` <> 'it''s'")
}
