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
    // Appwrite's SQL is Kelp's own, read one way: a \ is a character, $id a column.
    #expect(try SQLText.single("UPDATE t SET note = 'C:\\' WHERE $id = 'x;y'", .appwrite) != "")
    #expect(throws: DatabaseFailure.self) { try SQLText.single("DELETE FROM t; DELETE FROM u", .appwrite) }
}

/// What reaches past a Postgres database to its server (a program through COPY, its files, others' sessions) is
/// refused to agents, a read-only transaction letting it through; plain reads aren't.
@Test func whatReachesPastAPostgresDatabaseIsNamed() {
    for sql in [
        "COPY (SELECT 1) TO PROGRAM 'sh -c id'", "copy t from '/etc/passwd'",
        "DO $$ BEGIN EXECUTE 'CO' || 'PY t TO PROGRAM ''id'''; END $$", "SELECT lo_export(1, '/tmp/x')",
        "SELECT pg_catalog.PG_READ_FILE('/etc/passwd')", "SELECT pg_terminate_backend(pid) FROM pg_stat_activity",
        "SELECT * FROM dblink('host=x', 'SELECT 1') AS t(a int)", #"SELECT U&"pg_read_fil\0065"('/etc/passwd')"#,
        #"SELECT u& "pg_ls_di!0072" UESCAPE '!' ('/')"#
    ] {
        #expect(SQLText.pastTheDatabase(sql, .postgres) != nil, "\(sql)")
    }
    #expect(SQLText.pastTheDatabase("SELECT copy, program FROM t WHERE note = 'do it'", .postgres) == nil)
    #expect(SQLText.pastTheDatabase("COPY t TO 'x.csv'", .duckdb) == nil)   // -safe holds DuckDB to its file
}

/// MySQL's way to the server's files with the FILE privilege, which a read-only transaction lets through, is refused
/// to agents; a column named like it isn't.
@Test func whatReachesPastAMySQLDatabaseIsNamed() {
    for sql in [
        "SELECT * FROM users INTO OUTFILE '/tmp/u.csv'", "SELECT 0x3c3f INTO\nDUMPFILE '/var/www/x.php'",
        "SELECT load_file ('/etc/passwd')", "LOAD DATA LOCAL INFILE '/etc/hosts' INTO TABLE t"
    ] {
        #expect(SQLText.pastTheDatabase(sql, .mysql) != nil, "\(sql)")
    }
    #expect(SQLText.pastTheDatabase("SELECT outfile, load_files FROM t", .mysql) == nil)
}

/// A MySQL read through its client sets the server's own time limit by the name this server has (MySQL's in ms,
/// MariaDB's in s): a client killed in a container leaves no query running there.
@Test func aMySQLReadAsksTheServerToStopItToo() {
    let limit = MySQLRun.limit(15)
    #expect(limit.first?.contains("max_statement_time = 15'") == true)
    #expect(limit.first?.contains("max_execution_time = 15000'") == true)
    #expect(limit.dropFirst().allSatisfy { $0.contains("kelp_limit") })
}
