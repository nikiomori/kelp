import Core
import Foundation
import Testing

@testable import kelp

/// `kelp db query`'s last line: a change says the rows it touched (DDL none), a read how many of how many are shown and
/// why no more, past what's counted with a "+".
@Test func aQuerysFooterSaysWhatItDid() {
    func result(rows: Int, total: Int, changed: Int? = nil) -> QueryResult {
        QueryResult(
            id: "r", columns: changed == nil ? ["a"] : [], rows: Array(repeating: ["x"], count: rows),
            total: total, changed: changed, ms: 3)
    }
    #expect(
        Main.footer(result(rows: 0, total: 0, changed: 0), sql: "create table t (a int)", limit: nil) == "Done · 3 ms")
    #expect(
        Main.footer(result(rows: 0, total: 0, changed: 0), sql: " update t set a = 1", limit: nil)
            == "0 rows changed · 3 ms")
    #expect(
        Main.footer(result(rows: 0, total: 0, changed: 1), sql: "DELETE FROM t", limit: nil) == "1 row changed · 3 ms")
    #expect(Main.footer(result(rows: 1, total: 1), sql: "select 1", limit: nil) == "1 row · 3 ms")
    #expect(
        Main.footer(result(rows: 2, total: 5), sql: "select a from t", limit: 2)
            == "5 rows, the first 2 shown (--limit for more) · 3 ms")
    let kept = Main.footer(
        result(rows: QueryResult.kept, total: QueryResult.counted), sql: "select a from t", limit: 5000)
    #expect(kept.hasPrefix("100000+ rows, the first 1000 shown (Kelp keeps 1000 at most"), "\(kept)")
}

/// A row as JSON keeps a column named twice (a join's `id`s) as `id_2`, and NULL as null.
@Test func aRowsColumnsNamedTwiceAreBothKept() {
    #expect(
        Main.object(["id", "id", "id", "n"], ["1", "2", nil, "x"])
            == .object(["id": .string("1"), "id_2": .string("2"), "id_3": .null, "n": .string("x")]))
}

/// Cells are one short line each, columns padded to their widest (40 at most), the last one not padded.
@Test func cellsAndTablesPrintOnALine() {
    #expect(Main.cell(nil) == "NULL" && Main.cell("a\nb\tc") == "a⏎b c")
    let long = Main.cell(String(repeating: "x", count: 300))
    #expect(long.count == 200 && long.hasSuffix("…"))
    #expect(Main.table(["id", "name"], [["1", "Ann"], ["22", "Bo"]]) == "id  name\n1   Ann\n22  Bo")
    let wide = Main.table(["a", "b"], [[String(repeating: "w", count: 50), "z"]]).split(separator: "\n")
    #expect(wide[0] == "a" + String(repeating: " ", count: 39) + "  b")   // padded to 40, not to the 50 under it
}

/// A value given on the command line is JSON when it parses, else the text itself (`kelp settings set k dark`).
@Test func aCommandLineValueIsJSONOrText() {
    #expect(jsonOrText("3") == .int(3) && jsonOrText("true") == .bool(true))
    #expect(jsonOrText("[1]") == .array([.int(1)]) && jsonOrText("\"x\"") == .string("x"))
    #expect(jsonOrText("dark") == .string("dark") && jsonOrText("{oops") == .string("{oops"))
}

/// Tests that set the process's one `args`: one at a time.
@Suite(.serialized) struct Arguments {
    /// A flag takes the word after it out of the arguments, so what's left are the command's own; a flag with nothing
    /// after it is no flag.
    @Test func aFlagTakesItsValueOutOfTheArguments() {
        let was = args
        defer { args = was }
        args = ["query", "--db", "shop", "select 1", "--json"]
        #expect(flag("--db") == "shop" && has("--json") && !has("--json"))
        #expect(args == ["query", "select 1"])
        args = ["query", "--db"]
        #expect(flag("--db") == nil && args == ["query", "--db"])
    }
}

/// `kelp commit add`: the files, and each -m a paragraph of the message, as git joins them.
@Test func aProposedCommitsArgumentsAreItsFilesAndParagraphs() {
    let (files, message) = Main.planned(["a.swift", "b c.md", "-m", "feat: a", "-m", "Why."])
    #expect(files == ["a.swift", "b c.md"] && message == "feat: a\n\nWhy.")
    #expect(Main.planned(["a.swift"]).message.isEmpty)   // no -m: refused with its usage, never a commit of everything
}

/// With no --db, the only database is meant; a branch's own copy stands for the database it's a copy of, and is
/// listed as that.
@Test func aBranchesCopyIsMeantWhenNoDatabaseIsNamed() {
    let shop = DatabaseInfo(name: "shop", engine: .postgres, source: "compose.yaml", host: "localhost", port: 5432)
    var copy = DatabaseInfo(name: "shop_fix", engine: .postgres, host: "localhost", port: 5432, access: .free)
    copy.copy = BranchCopy(of: "shop", worktreeId: "w1", at: Date())
    let cache = DatabaseInfo(name: "cache", engine: .sqlite, source: "db/cache.sqlite3")
    #expect(Main.unnamed([shop]) == "shop" && Main.unnamed([]) == nil)
    #expect(Main.unnamed([shop, copy]) == "shop_fix")
    #expect(Main.unnamed([shop, copy, cache]) == nil)   // two to pick from: the copy and another database
    // A file copied into the branch's folder keeps its name: it doesn't stand for itself
    var own = DatabaseInfo(name: "shop", engine: .sqlite, source: "db/shop.sqlite3")
    own.copy = BranchCopy(of: "shop", worktreeId: "w1", at: Date())
    #expect(Main.unnamed([own]) == "shop")
    #expect(
        Main.place(copy) == "this branch's copy of shop localhost:5432" && Main.words(copy) == "read, change freely")
}

/// `kelp db schema` ends with the migrations not applied, when Kelp knows the database's migration tool.
@Test func aSchemasMigrationsEndIt() {
    let migrations = DatabaseMigrations(
        table: "schema_migrations",
        all: [
            .init(id: "20261118", name: "create_order_items", applied: true),
            .init(id: "20261122", name: "add_paid_at", applied: false)
        ])
    let schema = DatabaseSchema(tables: [.init(name: "orders", rows: 3)], migrations: migrations)
    #expect(
        Main.text(schema, columns: false)
            == "orders  3 rows\n\n1 migration not applied (schema_migrations): 20261122 add_paid_at")
    var done = migrations
    done.all[1].applied = true
    #expect(Main.text(DatabaseSchema(tables: [], migrations: done), columns: false).hasSuffix("all 2 applied"))
}
