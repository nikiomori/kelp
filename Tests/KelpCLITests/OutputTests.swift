import Core
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

/// What `kelp browser open` takes as typed: a local address is http, a bare host https, a URL as it is.
@Test func aBrowserAddressGetsItsScheme() {
    #expect(Main.address("localhost:3000") == "http://localhost:3000")
    #expect(Main.address("127.0.0.1:8080/x") == "http://127.0.0.1:8080/x")
    #expect(Main.address("example.com") == "https://example.com")
    #expect(Main.address("file:///tmp/a.html") == "file:///tmp/a.html" && Main.address("about:blank") == "about:blank")
}

/// An action's answer reads as one line, what came under it; a line from stdin splits into words as a shell would.
@Test func aBrowserAnswerIsALine() {
    let clicked: JSONValue = .object([
        "change": .string("page changed"), "element": .string(#"button "Check""#), "url": .string("http://x/"),
        "title": .string("X"), "new": .string(#"- text: "Invalid" [new]"#), "dialogs": .array([.string("alert \"Hi\"")])
    ])
    #expect(
        Main.browserText(.click, "e1", clicked)
            == "click e1 button \"Check\" → page changed\ndialog: alert \"Hi\"\n- text: \"Invalid\" [new]")
    let went: JSONValue = .object([
        "change": .string("new page"), "url": .string("http://x/two"), "title": .string("Two")
    ])
    #expect(Main.browserText(.click, "e3", went) == #"click e3 → new page "Two" http://x/two"#)
    let typed: JSONValue = .object(["shows": .string("+7 99"), "url": .string("u"), "title": .string("t")])
    #expect(Main.browserText(.type, "e5", typed) == #"type e5 → shows "+7 99""#)
    #expect(Main.browserText(.press, "Escape", .object([:])) == "press Escape → done")
    #expect(
        Main.browserText(.open, "", .object(["url": .string("u"), "title": .string("A \"b\"")])) == #"page "A \"b\"" u"#
    )
    #expect(Main.browserText(.snapshot, "", .string("- page")) == nil)
    #expect(Main.words(#"type e3 "a b" 'c "d"' e\ f"#) == ["type", "e3", "a b", #"c "d""#, "e f"])
    #expect(Main.words("  drag e1   '#col'  ") == ["drag", "e1", "#col"])
}

/// A value given on the command line is JSON when it parses, else the text itself (`kelp settings set k dark`).
@Test func aCommandLineValueIsJSONOrText() {
    #expect(jsonOrText("3") == .int(3) && jsonOrText("true") == .bool(true))
    #expect(jsonOrText("[1]") == .array([.int(1)]) && jsonOrText("\"x\"") == .string("x"))
    #expect(jsonOrText("dark") == .string("dark") && jsonOrText("{oops") == .string("{oops"))
}

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
