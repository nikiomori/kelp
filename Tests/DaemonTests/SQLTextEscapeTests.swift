import Core
import Testing

@testable import Daemon

// MARK: E'…' and where a statement ends

/// Postgres (and DuckDB) decide the backslash escape literal by literal: E'…' has it, a plain '…' doesn't. A text that
/// is one statement with escapes in every string and in none, but three as the server reads it, is refused: through
/// psql -c or duckdb what follows would run outside the read-only transaction.
@Test func aStatementPostgresSplitsAtAnEscapeStringIsRefused() {
    let hidden = #"'\'; COMMIT; DROP TABLE users --'"#
    for sql in [
        #"SELECT E'\'', "# + hidden,
        #"SELECT e'\'', "# + hidden,   // lower case
        #"SELECT E'\'' /* E' */, "# + hidden,   // comments around it
        "SELECT -- E'\n" + #"E'\'', "# + hidden,
        #"SELECT 1E'\'', "# + hidden,   // a number, then E'…'
        #"SELECT "a"E'\'', "# + hidden,
        // '…' on the next line goes on with the E'…' in Postgres, escapes and all
        "SELECT E'a'\n" + #"'\'', "# + hidden,
        "SELECT E'a' -- note\n" + #"'\'', "# + hidden,
        // E after a name's character isn't E'…': the plain string ends at its \'
        #"SELECT nameE'\'; COMMIT; DROP TABLE users --'"#,
        #"SELECT $$ E'\' $$, "# + hidden,   // an E'…' inside a dollar-quoted string is its text
        "SELECT 1$$ $$ ; DROP TABLE users; -- $$"   // a number, then a dollar-quoted string
    ] {
        for engine in [DatabaseInfo.Engine.postgres, .duckdb] {
            #expect(throws: DatabaseFailure.self, "\(engine): \(sql)") { try SQLText.single(sql, engine) }
        }
    }
}

/// The reading itself: which quote opens a string with escapes.
@Test func onlyAnEOfItsOwnOpensAnEscapeString() {
    let asPostgres = SQLText.Reading(backslash: .afterEAndOn, nested: true)
    let asDuckDB = SQLText.Reading(backslash: .afterE, nested: true)
    func count(_ sql: String, _ reading: SQLText.Reading = asPostgres) -> Int {
        SQLText.statements(sql, reading).count
    }
    #expect(count(#"SELECT E'\'', '\'; COMMIT; DROP TABLE users --'"#) == 3)
    #expect(count(#"SELECT E'\'; one string'"#) == 1)
    #expect(count(#"SELECT e'\'; one string'"#) == 1)
    #expect(count(#"SELECT 1E'\'; one string'"#) == 1)
    #expect(count(#"SELECT nameE'\'; SELECT 'two'"#) == 2)
    #expect(count(#"SELECT a1E'\'; SELECT 'two'"#) == 2)
    #expect(count(#"SELECT _e'\'; SELECT 'two'"#) == 2)
    #expect(count(#"SELECT $$E'\'$$; SELECT 'two'"#) == 2)
    // The other prefixes read as a plain string does: a \ isn't an escape of the quote
    for prefix in ["U&", "B", "X", "N", ""] {
        #expect(count("SELECT \(prefix)" + #"'\'; SELECT 'two'"#) == 2, "\(prefix)")
    }
    // A '…' after a line break goes on with the E'…' for Postgres; DuckDB reads it plain
    let onTheNextLine = "SELECT E'a'\n" + #"'\'; SELECT 'two'"#
    #expect(count(onTheNextLine) == 1)
    #expect(count(onTheNextLine, asDuckDB) == 2)
    #expect(count(#"SELECT E'a', '\'; SELECT 'two'"#) == 2)   // a comma between: a string of its own
}

/// What every reading takes for one statement still runs.
@Test func escapeStringsThatReadOneWayRun() throws {
    for sql in [
        #"SELECT E'tab\there; fine', 'C:\dir'"#, #"SELECT E'it\'s'"#, #"SELECT $$E'\''; x$$"#,
        "SELECT price$ FROM t WHERE code = '10e'", "SELECT 1e5, $1 FROM t"
    ] {
        #expect(try SQLText.single(sql, .postgres) == sql)
        #expect(try SQLText.single(sql, .duckdb) == sql)
    }
}
