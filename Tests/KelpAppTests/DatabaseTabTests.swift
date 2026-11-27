import AppKit
import Core
import Testing

@testable import BuiltinAgents
@testable import BuiltinDatabases
@testable import KelpKit

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
    // No primary key: the row found by all its values, one row touched
    #expect(
        edits.statements(table: "t", engine: .postgres, columns: ["a", "b", "c"], primary: [], rows: rows) == [
            #"UPDATE "t" SET "b" = 'o''k', "c" = NULL WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "t" "#
                + #"WHERE format('%s', "a") = '2' AND "#
                + #"format('%s', "b") = 'it''s' AND format('%s', "c") = 'x' LIMIT 1)"#
        ])
    #expect(
        edits.statements(table: "t", engine: .mysql, columns: ["a", "b", "c"], primary: [], rows: rows) == [
            "UPDATE `t` SET `b` = 'o''k', `c` = NULL WHERE `a` = '2' AND `b` = 'it''s' AND `c` = 'x' LIMIT 1"
        ])
    #expect(DatabaseInfo.Engine.mysql.table("public.my`t") == "`public.my``t`")   // a "." of MySQL's is the name's
    #expect(DatabaseInfo.Engine.postgres.table("audit.my\"t") == #""audit"."my""t""#)
    #expect(DatabaseInfo.Engine.mysql.literal(#"a\b"#) == #"'a\\b'"#)
}

/// A MySQL BINARY key, shown as hex, finds its row by those bytes, and text typed into a binary column stays text; a
/// keyless FLOAT is compared as the text it shows.
@Test func mySQLBytesAndFloatsFindTheirRows() {
    var edits = DatabaseEdits()
    let rows: [[String?]] = [["0x00ff", "0.1", "a"]]
    edits.set(row: 0, column: 2, to: "0x41", was: "a")
    let types = ["id": "binary(2)", "f": "float", "v": "varchar(9)"]
    #expect(
        edits.statements(
            table: "t", engine: .mysql, columns: ["id", "f", "v"], primary: ["id"], rows: rows, types: types)
            == ["UPDATE `t` SET `v` = '0x41' WHERE `id` = X'00ff'"])
    #expect(
        edits.statements(table: "t", engine: .mysql, columns: ["id", "f", "v"], primary: [], rows: rows, types: types)
            == ["UPDATE `t` SET `v` = '0x41' WHERE `id` = X'00ff' AND CONCAT(`f`) = '0.1' AND `v` = 'a' LIMIT 1"])
    #expect(DatabaseInfo.Engine.mysql.literal("0x41", type: "blob") == "X'41'")
    #expect(DatabaseInfo.Engine.mysql.literal("hello", type: "varbinary(9)") == "'hello'")
    #expect(DatabaseInfo.Engine.postgres.literal("0x41", type: "bytea") == "'0x41'")
    // A value shown only in part (a long blob) isn't written back: a copied row leaves it out, a pasted cell too
    var copied = DatabaseEdits()
    copied.add(["0x00ff", "0.1", "0x0102… (100 bytes)"])
    copied.set(row: 0, column: 2, to: "<9 bytes>", was: "a")
    #expect(
        copied.statements(
            table: "t", engine: .mysql, columns: ["id", "f", "v"], primary: ["id"], rows: rows,
            types: ["id": "binary(2)", "v": "blob"]) == ["INSERT INTO `t` (`id`, `f`) VALUES (X'00ff', '0.1')"])
}

@Test func aDatabaseTabsAddressNamesItsWorkspaceDatabaseAndRun() {
    let uri = DatabaseURI(worktree: "w1", name: "app dev", run: "r9")
    #expect(uri.uri == "db:w1/app%20dev?run=r9")
    #expect(DatabaseURI(uri.uri) == uri)
    #expect(DatabaseURI("db:w1/shop")?.run == nil && DatabaseURI("db:w1") == nil)
    #expect(DatabaseURI("db:") == nil && DatabaseURI("db:?") == nil)   // no body at all: an agent's `kelp open db:`
    // An imported name with a "?" is the name's, not the address's query
    let odd = DatabaseURI(worktree: "w1", name: "what?run=x", table: "a b")
    #expect(DatabaseURI(odd.uri) == odd)
}

/// Saving a table's edits: deletes and updates found by the key, new rows inserted with what was typed in them.
@Test func editsBecomeDeletesUpdatesAndInserts() throws {
    var edits = DatabaseEdits()
    let rows: [[String?]] = [["1", "a"], ["2", "b"]]
    edits.toggleDeleted(1)
    edits.set(row: 0, column: 1, to: "z", was: "a")
    edits.add([nil, "new"])
    edits.add([nil, nil])   // nothing typed: every column its default
    #expect(edits.count == 4)
    let sql = edits.statements(table: "t", engine: .postgres, columns: ["id", "v"], primary: ["id"], rows: rows)
    #expect(
        sql == [
            #"DELETE FROM "t" WHERE "id" = '2'"#, #"UPDATE "t" SET "v" = 'z' WHERE "id" = '1'"#,
            #"INSERT INTO "t" ("v") VALUES ('new')"#, #"INSERT INTO "t" DEFAULT VALUES"#
        ])
    // A table without a key takes new rows only.
    var only = DatabaseEdits()
    only.add(["x"])
    #expect(
        only.statements(table: "t", engine: .mysql, columns: ["v"], primary: [], rows: []) == [
            "INSERT INTO `t` (`v`) VALUES ('x')"
        ])
    var blank = DatabaseEdits()
    blank.add([nil])
    #expect(
        blank.statements(table: "t", engine: .mysql, columns: ["v"], primary: [], rows: []) == [
            "INSERT INTO `t` () VALUES ()"
        ])
    #expect(blank.statements(table: "t", engine: .appwrite, columns: ["v"], primary: [], rows: []).isEmpty)
    // A key the result doesn't hold in full is no key: the row is found by all its values.
    #expect(
        edits.statements(table: "t", engine: .postgres, columns: ["id", "v"], primary: ["id", "w"], rows: rows)
            .first == #"DELETE FROM "t" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "t" "#
            + #"WHERE format('%s', "id") = '2' AND format('%s', "v") = 'b' LIMIT 1)"#)
    // Without a key, SQLite finds a row by its values through its rowid, a NULL cell by IS NULL: of two identical
    // rows, one changes.
    let path = NSTemporaryDirectory() + "kelp-edits-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    _ = try run(
        path, "CREATE TABLE t (a INTEGER, b TEXT); INSERT INTO t VALUES (1, 'a'), (1, 'a'), (2, NULL), (2, NULL)")
    var keyless = DatabaseEdits()
    keyless.set(row: 0, column: 1, to: "z", was: "a")
    keyless.toggleDeleted(2)
    let saved = keyless.statements(
        table: "t", engine: .sqlite, columns: ["a", "b"], primary: [],
        rows: [["1", "a"], ["1", "a"], ["2", nil], ["2", nil]])
    #expect(
        saved == [
            #"DELETE FROM "t" WHERE rowid = (SELECT rowid FROM "t" WHERE "a" = '2' AND "b" IS NULL LIMIT 1)"#,
            #"UPDATE "t" SET "b" = 'z' WHERE rowid = (SELECT rowid FROM "t" WHERE "a" = '1' AND "b" = 'a' LIMIT 1)"#
        ])
    for statement in saved { #expect(try run(path, statement + "; SELECT changes()") == "1", "\(statement)") }
    #expect(try run(path, "SELECT group_concat(a || ':' || ifnull(b, 'NULL'), ' ') FROM t") == "1:z 1:a 2:NULL")
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
    #expect(
        ResultText.insert(["id", "b"], [["1", "\\x0102… (70 bytes)"]], table: "t", engine: .postgres)
            == #"INSERT INTO "t" ("id") VALUES ('1');"#)
    #expect(
        ResultText.insert(["b"], [["0x41"]], table: "t", engine: .mysql, types: ["blob"])
            == "INSERT INTO `t` (`b`) VALUES (X'41');")
}

/// Number columns stand right, found by their type ("interval" starts with "int", "point" ends with it: neither is
/// one); the read time turns into seconds past one.
@Test func numberColumnsAreFoundByType() {
    for type in ["integer", "double precision", "numeric(10,2)", "int unsigned", "REAL", "bigserial", "float8"] {
        #expect(ResultGrid.isNumber(type), "\(type)")
    }
    let others = ["interval", "point", "text", "character varying(20)", "timestamp with time zone", "json", "integer[]"]
    for type in others {
        #expect(!ResultGrid.isNumber(type), "\(type)")
    }
    #expect(DatabaseTab.took(84) == "84 ms")
    #expect(DatabaseTab.took(1513).hasSuffix(" s") && DatabaseTab.took(1513).contains("1"))
}

/// All My Databases: groups in name order with their databases, a blank group is none; a mention quotes what a
/// shell would split.
@MainActor @Test func allMyDatabasesGroupByNameAndMentionsQuote() {
    func db(_ name: String, _ group: String?) -> DatabaseInfo {
        var db = DatabaseInfo(name: name, engine: .postgres)
        db.group = group
        return db
    }
    let (groups, loose) = DatabasesPanel.grouped([
        db("a", "Dev 10"), db("b", nil), db("c", "Dev 2"), db("d", " "), db("e", "Dev 2")
    ])
    #expect(groups.map(\.0) == ["Dev 2", "Dev 10"])
    #expect(groups.first?.1.map(\.name) == ["c", "e"])
    #expect(loose.map(\.name) == ["b", "d"])
    #expect(DatabasesPanel.mention(database: "webdb dev") == "the database webdb dev (kelp db schema --db 'webdb dev')")
    #expect(
        DatabasesPanel.mention("orders", in: "shop") == "the table orders in shop (kelp db schema orders --db shop)")
}

/// A cell scrolled away comes back for a row scrolled to, set over in full: no yellow fill, tooltip or red strike of
/// the row it showed before.
@MainActor @Test func gridCellsAreReusedAndReset() throws {
    let grid = ResultGrid()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = grid.scroll
    defer { withExtendedLifetime(window) {} }
    grid.show(columns: ["name"], rows: (0..<500).map { ["r\($0)"] })
    grid.edits.set(row: 0, column: 0, to: String(repeating: "long ", count: 10), was: "r0")
    grid.edits.toggleDeleted(1)
    grid.changed()
    window.display()
    let cell = { (row: Int) in grid.table.view(atColumn: 1, row: row, makeIfNecessary: false) as? NSTextField }
    let edited = try #require(cell(0)), struck = try #require(cell(1))
    #expect(edited.drawsBackground && edited.toolTip != nil)
    grid.table.scrollRowToVisible(400)
    window.display()
    let shown = shownCells(grid.table).compactMap { $0 as? NSTextField }
    let back = try #require(shown.first { $0 === edited || $0 === struck })
    #expect(back.attributedStringValue.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
    #expect(!back.drawsBackground && back.toolTip == nil)
}

/// The card that asks shows an update by its key and the columns it changes, a delete by its first columns; an update
/// whose rows as they were aren't known has nothing to compare, so no rows.
@MainActor @Test func aChangesPreviewShowsItsKeyAndWhatChanges() {
    var update = QueryResult(
        id: "r", columns: ["status", "id", "total", "note"],
        rows: [["cancelled", "10", "5", "Expired"], ["cancelled", "20", "7", "x"]], total: 2, changed: 2, ms: 0)
    update.change = RowChange(
        kind: .update, table: "orders", key: ["id"], before: [["pending", "10", "5", nil], ["pending", "20", "7", "x"]])
    #expect(update.changedColumns == [0, 3])
    #expect(ChangePreview.columns(of: update) == [1, 0, 3])
    update.change?.before = nil
    #expect(ChangePreview.columns(of: update).isEmpty)
    update.change = RowChange(kind: .delete, table: "orders", key: ["id"])
    #expect(ChangePreview.columns(of: update) == [1, 0, 2, 3])
    update.change = nil
    #expect(ChangePreview.columns(of: update).isEmpty)
    #expect(RowChange(kind: .insert, table: "\"Order Items\"").tableName == "Order Items")
}

/// A query names its tab, picks no table in the list and starts from the table that was shown. What the tab says
/// when there are no rows sits over the rows' scroll view, not in it (there the rows' ground covers it).
@MainActor @Test func aQueryNamesItsTabAndStartsFromTheTableShown() {
    let tab = DatabaseTab(uri: "db:w1/shop?table=orders", app: AppModel(builtins: []))
    #expect(tab.title == "orders · shop")
    #expect(tab.empty.superview === tab.grid.area && tab.grid.scroll.superview === tab.grid.area)
    tab.schema = DatabaseSchema(tables: [DatabaseSchema.Table(name: "items"), DatabaseSchema.Table(name: "orders")])
    tab.sidebar.current = "orders"
    tab.chosen = true
    tab.mode = .query
    tab.startedQuery()
    #expect(tab.title == "Query · shop" && tab.sidebar.current == nil)
    #expect(tab.editor.text == #"SELECT * FROM "orders" LIMIT 100;"#)
    #expect(tab.editor.selectedRange.length == (tab.editor.text as NSString).length)   // typing replaces it
    #expect(tab.grid.scroll.isHidden)   // no empty header over "Run a Statement"
    #expect(DatabaseTab.title("shop", showing: .table("users")) == "users · shop")
    #expect(DatabaseTab.title("shop", showing: .run("r1")) == "shop")
}

/// Saved queries and the draft are Kelp's state as the app holds it (`uiState`): read from there and written there, so
/// the app's copy never goes stale behind a write of its own.
@MainActor @Test func aDatabasesQueriesAreTheAppsState() {
    let app = AppModel(builtins: [])
    app.uiState["db.queries/w1/shop"] = .array([.object(["name": .string("big"), "sql": .string("SELECT 1")])])
    app.uiState["db.draft/w1/shop"] = .string("SELECT 2")
    let tab = DatabaseTab(uri: "db:w1/shop?table=orders", app: app)
    tab.loadQueries()
    #expect(tab.sidebar.saved.map(\.name) == ["big"] && tab.editor.text == "SELECT 2")
    tab.started = true
    tab.editor.setText("SELECT 3")
    tab.keepDraft()
    #expect(app.uiState["db.draft/w1/shop"] == .string("SELECT 3"))
}

/// A run's rows that couldn't be read (no daemon here) say so: "Not Kept" is only for rows Kelp let go.
@MainActor @Test func aRunsRowsThatCantBeReadAreNotCalledNotKept() async {
    let tab = DatabaseTab(uri: "db:w1/shop?run=r1", app: AppModel(builtins: []))
    await tab.showRun("r1")
    func texts(_ v: NSView) -> [String] {
        [(v as? NSTextField)?.stringValue].compactMap { $0 } + v.subviews.flatMap(texts)
    }
    let said = texts(tab.empty)
    #expect(said.contains("Can’t Read shop") && !said.contains("Not Kept"), "\(said)")
}

/// A foreign key's target keeps its schema: the column is what follows the last ".".
@Test func aForeignKeyNamesItsTargetsSchema() {
    let column = {
        DatabaseSchema.Column(name: "user_id", type: "uuid", nullable: false, primary: false, references: $0)
    }
    #expect(column("auth.users.id").target.map { [$0.table, $0.column] } == ["auth.users", "id"])
    #expect(column("users.id").target.map { [$0.table, $0.column] } == ["users", "id"])
    #expect(column(nil).target == nil && column("id").target == nil)
}
