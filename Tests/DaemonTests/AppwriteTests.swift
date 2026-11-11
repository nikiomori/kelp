import Core
import Foundation
import Testing

@testable import Daemon

/// The tab's page, filter, count and edits, read as Appwrite's queries.
@Test func theTabsSQLBecomesAppwritesQueries() throws {
    let page = try AppwriteSQL.parse(
        #"SELECT * FROM "fields" WHERE ("year" = '2025') AND ("crop" LIKE '%Со%' OR "note" IS NULL) "#
            + #"ORDER BY "area" DESC, "$id" ASC LIMIT 200 OFFSET 400"#)
    guard case .select(let s) = page else { throw DatabaseFailure.failed("not a select") }
    #expect(s.table == "fields" && s.limit == 200 && s.offset == 400 && s.orders.map(\.ascending) == [false, true])
    let kinds = AppwriteWire.Kinds(columns: ["$id", "year", "crop"], types: ["year": ("integer", false)])
    let queries = try s.condition.map { kinds.queries($0) }.map { try $0.map(json) } ?? []
    #expect(
        queries == [
            #"{"attribute":"year","method":"equal","values":[2025]}"#,
            #"{"method":"or","values":[{"attribute":"crop","method":"contains","values":["Со"]},"#
                + #"{"attribute":"note","method":"isNull"}]}"#
        ])
    #expect(
        try AppwriteSQL.parse(#"SELECT count(*) FROM "t" WHERE "a" NOT IN ('x', 'y')"#)
            == .select(
                .init(
                    table: "t", count: true,
                    condition: .all([.test("notEqual", "a", [.text("x")]), .test("notEqual", "a", [.text("y")])]))))
    #expect(
        try AppwriteSQL.parse(#"UPDATE "t" SET "b" = 'o''k', "c" = NULL WHERE "$id" = 'r1'"#)
            == .update("t", [("b", .text("o'k")), ("c", .null)], .test("equal", "$id", [.text("r1")])))
    #expect(
        try AppwriteSQL.parse(#"INSERT INTO "t" ("a", "n") VALUES ('x', 3), ('y', -1.5)"#)
            == .insert(
                .init(
                    table: "t", columns: ["a", "n"], rows: [[.text("x"), .number("3")], [.text("y"), .number("-1.5")]]))
    )
    #expect(throws: DatabaseFailure.self) { try AppwriteSQL.parse(#"DELETE FROM "t""#) }   // no WHERE: refused
    #expect(throws: DatabaseFailure.self) { try AppwriteSQL.parse("SELECT a FROM t JOIN u ON a = b") }
    #expect(AppwriteWire.Kinds.coerce("t", ("boolean", false)) as? Bool == true)
    #expect(AppwriteWire.Kinds.coerce(#"["a","b"]"#, ("string", true)) as? [String] == ["a", "b"])
    #expect(AppwriteWire.text(NSNumber(value: true)) == "true" && AppwriteWire.text(["k": 1]) == #"{"k":1}"#)
}

private func json(_ q: [String: Any]) throws -> String {
    String(
        decoding: try JSONSerialization.data(withJSONObject: q, options: [.sortedKeys, .withoutEscapingSlashes]),
        as: UTF8.self)
}

/// Against a real Appwrite (KELP_TEST_APPWRITE=https://…): its version without a key, a wrong key in its words.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_TEST_APPWRITE"] != nil))
func appwriteAnswersInItsOwnWords() async throws {
    let host = ProcessInfo.processInfo.environment["KELP_TEST_APPWRITE"] ?? ""
    var db = DatabaseInfo(name: "aw", engine: .appwrite, host: host, user: "kelp-no-such-project")
    db.database = "main"
    let c = DatabaseConnection(database: db, password: "not-a-key")
    #expect(try await AppwriteWire(c: c).version()?.hasPrefix("Appwrite 1.") == true)
    do {
        _ = try await AppwriteWire(c: c).read(#"SELECT * FROM "t" WHERE "a" LIKE '%x+y%' LIMIT 5"#, timeout: 10)
        Issue.record("a wrong key read rows")
    } catch let failure as DatabaseFailure { print("APPWRITE SAID:", failure.message) }
}

/// The whole way through kelpd against a real Appwrite with a project "kelptest", database "main" and its "fields"
/// table (KELP_TEST_APPWRITE_KEY; run with KELP_KEYCHAIN_SERVICE set): schema, a page, a filter, a count, the tab's
/// edits in one transaction, a failed one taking nothing with it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["KELP_TEST_APPWRITE_KEY"] != nil))
func appwriteThroughKelpd() async throws {
    let env = ProcessInfo.processInfo.environment
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    var db = DatabaseInfo(
        name: "aw", engine: .appwrite, host: env["KELP_TEST_APPWRITE"] ?? "", user: "kelptest", access: .free)
    db.database = "main"
    _ = try w.d.workspaces.databases.save(wt.id, db, password: env["KELP_TEST_APPWRITE_KEY"])
    defer { Task { _ = try? await w.c.call(DatabaseRemove(worktreeId: wt.id, name: "aw")) } }
    func q(_ sql: String) async throws -> QueryResult {
        try await w.c.call(DatabaseQuery(worktreeId: wt.id, database: "aw", sql: sql))
    }

    let check = try await w.c.call(DatabaseCheck(worktreeId: wt.id, database: db))
    #expect(check.version == "Appwrite 1.8.1" && check.databases == ["main"] && check.tables == 1)
    let fields = try #require(try await w.c.call(DatabaseSchemaRead(worktreeId: wt.id, database: "aw")).tables.first)
    #expect(fields.name == "fields" && fields.comment == "Поля" && fields.columns.first?.primary == true)
    #expect(
        fields.columns.map(\.name) == [
            "$id", "field_name", "year", "area", "active", "tags", "$createdAt", "$updatedAt"
        ])
    #expect(fields.columns.first { $0.name == "tags" }?.type == "string[]" && fields.indexes == ["by_year (year)"])

    let page = try await q(#"SELECT * FROM "fields" ORDER BY "$id" ASC LIMIT 200 OFFSET 0"#)
    #expect(
        page.rows.map { Array($0.prefix(6)) } == [
            ["f1", "Участок 1", "2025", "123", "true", #"["соя","север"]"#],
            ["f2", "Участок 2", "2025", "45.5", "false", "[]"],
            ["f3", "Поле+3", "2024", "10", nil, "[]"]
        ])
    let filtered = try await q(
        #"SELECT "$id" FROM "fields" WHERE ("year" = '2025') AND ("field_name" LIKE '%2%' OR "active" = 'true')"#)
    #expect(filtered.rows == [["f1"], ["f2"]])
    #expect(try await q(#"SELECT "$id" FROM "fields" WHERE "field_name" LIKE '%+3'"#).rows == [["f3"]])
    #expect(try await q(#"SELECT count(*) FROM "fields" WHERE "area" > '20'"#).rows == [["2"]])

    // The tab's edits: all at once
    _ = try await w.c.call(
        DatabaseApply(
            worktreeId: wt.id, database: "aw",
            statements: [
                #"UPDATE "fields" SET "year" = '2026', "tags" = '["a"]' WHERE "$id" = 'f2'"#,
                #"INSERT INTO "fields" ("$id", "field_name", "area") VALUES ('f4', 'Новое', '1.25')"#
            ]))
    #expect(try await q(#"SELECT "year", "tags" FROM "fields" WHERE "$id" = 'f2'"#).rows == [["2026", #"["a"]"#]])
    // One that fails takes the others back
    await #expect(throws: (any Error).self) {
        _ = try await w.c.call(
            DatabaseApply(
                worktreeId: wt.id, database: "aw",
                statements: [
                    #"DELETE FROM "fields" WHERE "$id" = 'f4'"#,
                    #"UPDATE "fields" SET "year" = 'x' WHERE "$id" = 'no-such-row'"#
                ]))
    }
    #expect(try await q(#"SELECT count(*) FROM "fields""#).rows == [["4"]])
    // As it was, for the next run
    _ = try await q(#"DELETE FROM "fields" WHERE "$id" = 'f4'"#)
    _ = try await q(#"UPDATE "fields" SET "year" = '2025', "tags" = '[]' WHERE "$id" = 'f2'"#)
}
