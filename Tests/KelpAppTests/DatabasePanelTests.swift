import AppKit
import Core
import Testing

@testable import BuiltinDatabases

private func db(
    _ name: String, _ engine: DatabaseInfo.Engine = .postgres, host: String? = nil, database: String? = nil,
    path: String? = nil, ssh: String? = nil
) -> DatabaseInfo {
    var db = DatabaseInfo(name: name, engine: engine)
    db.host = host
    db.database = database
    db.path = path
    db.ssh = ssh
    return db
}

/// Kelp's name for an unnamed one ("AGR_GIS@pg-prod-ro") shows without its host, which the line under it says; a name
/// with an "@" of its own stays whole.
@MainActor @Test func aDatabasesShownNameLeavesOutTheHostItsNameEndsWith() {
    #expect(DatabasePanelRows.shownName(db("AGR_GIS@pg-prod-ro", host: "pg-prod-ro.internal")) == "AGR_GIS")
    #expect(DatabasePanelRows.shownName(db("me@work", host: "db.example.com")) == "me@work")
    #expect(DatabasePanelRows.shownName(db("@pg", host: "pg")) == "@pg")   // nothing before the "@"
    #expect(DatabasePanelRows.shownName(db("AGR_GIS@pg-prod-ro")) == "AGR_GIS@pg-prod-ro")   // no host to check
}

/// Where a database is: a file by its name, a server by host and database (not the database again when it's the name
/// shown), and the ssh host it's reached through.
@MainActor @Test func aDatabasesPlaceIsItsFileOrItsHostAndDatabase() {
    #expect(DatabasePanelRows.place(db("shop", .sqlite, path: "/p/data/shop.sqlite3")) == "shop.sqlite3")
    #expect(DatabasePanelRows.place(db("app", host: "db.example.com", database: "app_dev")) == "db.example.com/app_dev")
    #expect(DatabasePanelRows.place(db("webdb", host: "box", database: "WebDB")) == "box")
    #expect(DatabasePanelRows.place(db("app", host: "localhost", database: "app", ssh: "jump")) == "localhost via jump")
    #expect(DatabasePanelRows.place(db("bare")) == "")   // nothing known: an empty line
}

/// A branch's copy says so: on its own row where and whose branch, under its database whether agents here use it.
@MainActor @Test func aBranchesCopySaysWhatItIs() {
    var copy = db("shop-fix", .sqlite, path: "/p/shop-fix.sqlite3")
    #expect(DatabasePanelRows.copyWords(copy, branch: "fix/orders", under: false) == nil)   // not a copy
    copy.copy = BranchCopy(of: "shop", worktreeId: "w", at: Date())
    #expect(
        DatabasePanelRows.copyWords(copy, branch: "fix/orders", under: false)
            == "shop-fix.sqlite3 · copy for fix/orders")
    copy.access = .read
    #expect(DatabasePanelRows.copyWords(copy, branch: "fix/orders", under: true) == "agents here use it")
    copy.access = .hidden
    #expect(DatabasePanelRows.copyWords(copy, branch: "fix/orders", under: true) == "made just now")
}

/// A run's line: how many rows it read or changed and when, else the word for what stopped it, in its colour.
@MainActor @Test func aRunSaysWhatItDidOrWhatStoppedIt() {
    func run(_ state: DatabaseRun.State, rows: Int? = nil, changed: Int? = nil) -> DatabaseRun {
        DatabaseRun(
            id: "r", database: "d", sql: "", session: nil, at: Date(), state: state, rows: rows, changed: changed)
    }
    #expect(DatabasePanelRows.outcome(run(.done, rows: 200)).hasPrefix("200 · "))
    #expect(DatabasePanelRows.outcome(run(.done, rows: 5, changed: 3)).hasPrefix("3 changed · "))   // a change says so
    #expect(
        DatabaseRun.State.allCases.filter { $0 != .done }.map { DatabasePanelRows.outcome(run($0)) }.sorted()
            == ["asks", "denied", "failed", "refused"])
    #expect(DatabasePanelRows.color(.asks) == .textOrange)
    #expect(DatabasePanelRows.color(.refused) == .textRed && DatabasePanelRows.color(.failed) == .textRed)
    #expect(
        DatabasePanelRows.color(.done) == .secondaryLabelColor
            && DatabasePanelRows.color(.denied) == .secondaryLabelColor)
}

/// The environment a list shows: Production is only ever the user's word; else what they said; else Local for a file
/// or this Mac's server; a server elsewhere nobody tagged shows none.
@MainActor @Test func aDatabasesShownEnvironmentIsTheUsersWordOrWhereItIs() {
    var tagged = db("app", host: "db.example.com")
    tagged.production = true
    tagged.environment = .staging
    #expect(DatabaseLook.shownStage(tagged) == .production)
    tagged.production = false
    #expect(DatabaseLook.shownStage(tagged) == .staging)
    #expect(DatabaseLook.shownStage(db("shop", .sqlite, path: "/p/shop.sqlite3")) == .local)
    #expect(DatabaseLook.shownStage(db("app", host: "localhost")) == .local)
    #expect(DatabaseLook.shownStage(db("app", host: "db.example.com")) == nil)
    #expect(DatabaseLook.shownStage(db("app", host: "localhost", ssh: "box")) == nil)   // localhost of another machine
}

/// The form's word under the environment: what it means for agents, and a warning when one elsewhere is called Local
/// or Development.
@MainActor @Test func theFormWarnsWhenADatabaseElsewhereIsntCalledProduction() {
    let warning = "Not on this Mac: pick Production if it is one."
    #expect(DatabaseForm.why(.local, elsewhere: true) == warning)
    #expect(DatabaseForm.why(.development, elsewhere: true) == warning)
    #expect(DatabaseForm.why(.staging, elsewhere: true) == DatabaseLook.meaning(.staging))
    #expect(DatabaseForm.why(.local, elsewhere: false) == DatabaseLook.meaning(.local))
}

/// A table's name quoted for its engine: Postgres reads "audit.orders" as schema and table, MySQL quotes with
/// backticks and keeps a "." as part of the name.
@MainActor @Test func aTablesNameIsQuotedForItsEngine() {
    #expect(DatabaseEdits.name("audit.orders", .postgres) == #""audit"."orders""#)
    #expect(DatabaseEdits.name("a.b", .mysql) == "`a.b`")
    #expect(DatabaseEdits.name("orders", .sqlite) == #""orders""#)
}

/// The grid's row height follows the density setting; anything unknown is compact.
@MainActor @Test func theGridsRowsAreAsTallAsTheDensitySays() {
    #expect(ResultGrid.height("comfortable") > ResultGrid.height("normal"))
    #expect(ResultGrid.height("normal") > ResultGrid.height("compact"))
    #expect(ResultGrid.height("whatever") == ResultGrid.height("compact"))
}

/// JSON keeps numbers as numbers but not a code with a leading zero, a cell's JSON as JSON, and text that only starts
/// like JSON as text.
@MainActor @Test func rowsCopyAsJSONKeepTheirTypes() {
    let json = ResultText.json(["zip", "n", "f", "bad"], [["02134", "0", "1.5", "{not json"]])
    #expect(json.contains(#""zip" : "02134""#) && json.contains(#""n" : 0"#) && json.contains(#""f" : 1.5"#))
    #expect(json.contains(#""bad" : "{not json""#))
    #expect(ResultText.tsv(["a", "b"], [["1", nil]]) == "a\tb\n1\tNULL")
}
