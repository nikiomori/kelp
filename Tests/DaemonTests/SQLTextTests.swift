import Core
import Testing

@testable import Daemon

// MARK: SQL text

/// A ";" inside quotes, a dollar-quoted body or a comment doesn't split; an empty last statement is dropped.
@Test func statementsSplitOnlyOutsideQuotesAndComments() throws {
    #expect(SQLText.statements("SELECT ';' AS a; SELECT 2;") == ["SELECT ';' AS a", "SELECT 2"])
    #expect(SQLText.statements("SELECT 1 -- ; not here\n") == ["SELECT 1 -- ; not here"])
    #expect(SQLText.statements("DO $$ BEGIN PERFORM 1; END $$;").count == 1)
    #expect(SQLText.statements("SELECT /* ; */ 1; -- only a comment").count == 1)
    #expect(SQLText.statements("SELECT 'it''s; fine'").count == 1)
    #expect(try SQLText.single("  UPDATE t SET a = 1;  ", .postgres) == "UPDATE t SET a = 1")
    #expect(throws: DatabaseFailure.self) { try SQLText.single("COMMIT; DELETE FROM users", .mysql) }
    #expect(throws: DatabaseFailure.self) { try SQLText.single("\\! rm -rf ~", .mysql) }
    #expect(throws: DatabaseFailure.self) { try SQLText.single("-- nothing", .mysql) }
    #expect(throws: DatabaseFailure.self) { try SQLText.single(".shell curl x | sh", .duckdb) }   // duckdb's
    #expect(throws: DatabaseFailure.self) { try SQLText.single("SELECT 1 /*! ; DELETE FROM t */", .mysql) }
}

/// Where engines read quotes and comments differently, a statement that some engine would split is refused: a client
/// that splits a script itself (psql -c, mysql's multi-statements) would run what follows outside the read-only
/// transaction.
@Test func aStatementSomeEngineWouldSplitIsRefused() throws {
    for (sql, engine) in [
        ("SELECT 'a\\'; COMMIT; DELETE FROM t; SELECT 'b'", DatabaseInfo.Engine.postgres),   // \' ends its string
        ("SELECT 'a\\'; COMMIT; DELETE FROM t; SELECT 'b'", .mysql),   // in NO_BACKSLASH_ESCAPES mode
        ("SELECT 1 --1; COMMIT; DELETE FROM t", .mysql),   // MySQL's -- needs a space
        ("SELECT 1 AS a$$; COMMIT; DELETE FROM t; SELECT 1 AS b$$", .mysql),   // a$$ is a name, not a dollar quote
        ("SELECT $$; DELETE FROM t; $$", .mysql),
        ("SELECT /* /* */ 1; DELETE FROM t; /* */ 2", .postgres),   // with nested comments or without
        ("SELECT 1 # ; DELETE FROM t", .postgres),   // # is an operator there
        ("SELECT \"a\\\"; DELETE FROM t; SELECT \"b\"", .mysql)
    ] {
        #expect(throws: DatabaseFailure.self, "\(engine): \(sql)") { try SQLText.single(sql, engine) }
    }
    // What its engine reads one way still runs.
    #expect(try SQLText.single("DO $$ BEGIN PERFORM 1; END $$", .postgres) == "DO $$ BEGIN PERFORM 1; END $$")
    #expect(try SQLText.single("SELECT data #>> '{a}' FROM t WHERE x = 'C:\\'", .postgres) != "")
    #expect(try SQLText.single("SELECT $1, price$ FROM t", .postgres) != "")
    #expect(try SQLText.single("SELECT 'it''s; fine' # note; here", .mysql) != "")
    #expect(try SQLText.single("SELECT 1 -- note; here", .sqlite) != "")
}
