import Core
import Foundation

/// SQL as text: its statements, and what kind the first one is. Quotes ('…', "…", `…`, $tag$…$tag$) and comments
/// (-- …, /* … */) are skipped, so a ";" inside them doesn't split.
enum SQLText {
    /// How an engine reads quotes and comments, where engines differ: MySQL takes \\' as an escaped quote (unless
    /// NO_BACKSLASH_ESCAPES), `#` as a comment and `--` as one only before a space, and has no $tag$; Postgres (and
    /// DuckDB, its parser) nests /* */ and has a \\ escape only in E'…' (or with standard_conforming_strings off).
    struct Reading {
        var backslash = true, mysql = false, nested = false, dollar = true

        /// Each way `engine` may read a statement: it's one only if every one of them says so (`single`).
        static func of(_ engine: DatabaseInfo.Engine) -> [Reading] {
            switch engine {
            case .postgres, .duckdb:
                [false, true].flatMap { backslash in
                    [false, true].map { Reading(backslash: backslash, nested: $0) }
                }
            case .mysql: [false, true].map { Reading(backslash: $0, mysql: true, dollar: false) }
            // Appwrite's is Kelp's own narrow SQL, translated to its API one statement at a time
            case .sqlite, .appwrite: [Reading(backslash: false, dollar: false)]
            }
        }
    }

    /// The statements, each trimmed, empty ones (a trailing ";", only a comment) dropped.
    static func statements(_ sql: String, _ reading: Reading = Reading()) -> [String] {
        let chars = Array(sql)
        var parts: [String] = [], start = 0
        walk(chars, reading, comment: { _ in }) { at in
            parts.append(String(chars[start..<at]))
            start = at + 1
        }
        if start < chars.count { parts.append(String(chars[start...])) }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !code($0).isEmpty }
    }

    /// The statement with each comment a space, as its engine reads it (`reading`): what a text check reads, since
    /// the engine takes `INTO/**/OUTFILE` as `INTO OUTFILE`.
    static func uncommented(_ sql: String, _ reading: Reading) -> String {
        let chars = Array(sql)
        var out = "", from = 0
        walk(
            chars, reading,
            comment: { range in
                out += String(chars[from..<range.lowerBound]) + " "
                from = range.upperBound
            }
        ) { _ in }
        return out + String(chars[from...])
    }

    /// Reads `chars` as `reading` says, skipping quotes: each comment's range, and each ";" that ends a statement.
    private static func walk(
        _ chars: [Character], _ reading: Reading, comment: (Range<Int>) -> Void, ends: (Int) -> Void
    ) {
        var i = 0
        func at(_ index: Int) -> Character? { index < chars.count ? chars[index] : nil }
        func skip(to end: String, from index: Int) -> Int {
            let target = Array(end)
            var position = index
            while position < chars.count {
                if Array(chars[position..<min(position + target.count, chars.count)]) == target {
                    return position + target.count
                }
                position += 1
            }
            return chars.count
        }
        func endOfComment(from index: Int) -> Int {
            var depth = 1, j = index
            while j < chars.count {
                if chars[j] == "*", at(j + 1) == "/" {
                    depth -= 1
                    j += 2
                    if depth == 0 || !reading.nested { return j }
                } else if reading.nested, chars[j] == "/", at(j + 1) == "*" {
                    depth += 1
                    j += 2
                } else {
                    j += 1
                }
            }
            return chars.count
        }
        while i < chars.count {
            let char = chars[i], next = at(i + 1)
            let afterWord = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_")
            switch char {
            case "'", "\"", "`":
                var end = i + 1
                while end < chars.count {
                    if chars[end] == char {
                        if at(end + 1) == char {
                            end += 2   // '' inside a string
                            continue
                        }
                        break
                    }
                    if reading.backslash, chars[end] == "\\", char != "`", end + 1 < chars.count { end += 1 }
                    end += 1
                }
                i = end + 1
            case "-" where next == "-" && (!reading.mysql || at(i + 2).map { $0.isWhitespace } ?? true):
                let from = i
                i = skip(to: "\n", from: i + 2)
                comment(from..<i)
            case "#" where reading.mysql:
                let from = i
                i = skip(to: "\n", from: i + 1)
                comment(from..<i)
            case "/" where next == "*":
                let from = i
                i = endOfComment(from: i + 2)
                comment(from..<i)
            case "$" where reading.dollar && !afterWord:
                // $$ or $tag$: a Postgres dollar-quoted string, to the same tag (a tag doesn't start with a digit).
                var end = i + 1
                while end < chars.count,
                    chars[end].isLetter || chars[end] == "_" || (end > i + 1 && chars[end].isNumber)
                {
                    end += 1
                }
                if end < chars.count, chars[end] == "$" {
                    i = skip(to: String(chars[i...end]), from: end + 1)
                } else {
                    i += 1
                }
            case ";":
                ends(i)
                i += 1
            default: i += 1
            }
        }
    }

    /// The statement without its comments, for telling what it is.
    static func code(_ sql: String) -> String {
        var text = sql
        while true {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("--") || trimmed.hasPrefix("#") {
                text = trimmed.firstIndex(of: "\n").map { String(trimmed[trimmed.index(after: $0)...]) } ?? ""
            } else if trimmed.hasPrefix("/*"), let end = trimmed.range(of: "*/") {
                text = String(trimmed[end.upperBound...])
            } else {
                return trimmed
            }
        }
    }

    /// Its first word, upper-cased: SELECT, UPDATE, WITH…
    static func verb(_ sql: String) -> String {
        String(code(sql).prefix { $0.isLetter }).uppercased()
    }

    /// The one statement a call may run: more, or a client command (psql's \…, duckdb's .…), is refused before
    /// anything runs. One at a time keeps a read-only transaction whole (a "COMMIT; DELETE …" would leave it) and
    /// what the user allows all that runs. It's read every way its engine might read it (`Reading`): a client that
    /// splits a script itself (psql -c, mysql, MySQL's multi-statements) splits it as its engine does, so where the
    /// readings disagree on where it ends, it's refused.
    static func single(_ sql: String, _ engine: DatabaseInfo.Engine) throws -> String {
        let readings = Reading.of(engine)
        let all = statements(sql, readings[0])
        guard let only = all.first else { throw DatabaseFailure.failed("There's no statement to run.") }
        guard all.count == 1 else {
            throw DatabaseFailure.failed("One statement at a time: this has \(all.count). Run them one by one.")
        }
        guard readings.allSatisfy({ statements(sql, $0).count <= 1 }) else {
            throw DatabaseFailure.failed(
                "Kelp can't tell where this statement ends (a \\' or --x reads differently in each engine): "
                    + "write the quote as '' and put a space after --.")
        }
        let code = code(only)
        guard !code.hasPrefix("\\"), !code.hasPrefix(".") else {
            throw DatabaseFailure.failed(
                "That's a client's command (psql's \\…, duckdb's .…), not SQL: Kelp runs SQL only.")
        }
        guard !only.contains("/*!"), !only.contains("/*M!") else {
            throw DatabaseFailure.failed(
                "MySQL runs what's in /*! … */: Kelp doesn't send those. Write it as plain SQL.")
        }
        return only
    }

    /// What reaches past a Postgres database to the server it runs on, and a read-only transaction lets through: COPY
    /// (to a file or a program), a DO block (whose EXECUTE builds a statement no text check sees), the functions that
    /// read or write the server's files or end others' sessions, and the built-in ones that run a query given as text
    /// (`query_to_xml('pg_read' || '_file(…)', …)`, `ts_stat`), which no text check reads, and a name spelled in
    /// Unicode escapes (`U&"…"`), which the check couldn't read either. Refused to agents with why;
    /// nil: none of it. A text check, so a function of the database's own can still do these: the role it connects as
    /// bounds that (a production database refuses agents a superuser, `Databases.query`).
    static func pastTheDatabase(_ sql: String, _ engine: DatabaseInfo.Engine) -> String? {
        // Read as the engine reads it, each comment a space: every way it may (`Reading.of`)
        for reading in Reading.of(engine) {
            if let why = pastTheDatabase(read: uncommented(sql, reading), engine) { return why }
        }
        return nil
    }

    private static func pastTheDatabase(read sql: String, _ engine: DatabaseInfo.Engine) -> String? {
        // DuckDB's -safe holds it to its file
        if engine == .mysql { return pastTheMySQLDatabase(sql) }
        guard engine == .postgres else { return nil }
        switch verb(sql) {
        case "COPY": return "COPY reaches the server's files and programs: read with SELECT instead."
        case "DO": return "A DO block runs statements Kelp can't read first: run each as a statement of its own."
        default: break
        }
        // U&"pg_read_fil\0065": a name spelled in escapes, which no word check reads
        if sql.range(of: #"\bU&\s*["']"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "Kelp doesn't run U&'…' or U&\"…\" for agents: write the name or text as it is."
        }
        let pattern =
            #"\b(lo_import|lo_export|pg_read_file|pg_read_binary_file|pg_ls_\w+|pg_stat_file|pg_promote|"#
            + #"pg_file_write|pg_terminate_backend|pg_cancel_backend|pg_reload_conf|pg_rotate_logfile|dblink\w*|"#
            + #"query_to_xml\w*|query_to_xmlschema|ts_stat|ts_rewrite)\b"#
        guard let found = sql.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return "\(sql[found].lowercased()) can reach past the database to its server: Kelp doesn't run it for agents."
    }

    /// MySQL's own way past the database to the server's files, which a read-only transaction lets through with the
    /// FILE privilege: SELECT … INTO OUTFILE / DUMPFILE, LOAD_FILE(), LOAD DATA … INFILE.
    private static func pastTheMySQLDatabase(_ sql: String) -> String? {
        let pattern = #"\b(INTO\s+(OUTFILE|DUMPFILE)|LOAD_FILE\s*\(|LOAD\s+(DATA|XML)\b)"#
        guard sql.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return "It reads or writes the server's files: Kelp doesn't run it for agents."
    }

    /// Whether it may run as a read, the database refusing a change in its read-only transaction. Not MySQL's DDL nor
    /// anything else but a read: MySQL commits the transaction before a DROP or ALTER and runs it outside.
    static func mayTryAsRead(_ sql: String, _ engine: DatabaseInfo.Engine) -> Bool {
        engine != .mysql
            || ["SELECT", "SHOW", "DESC", "DESCRIBE", "EXPLAIN", "WITH", "TABLE", "VALUES"].contains(verb(sql))
    }

    /// Whether a change can be tried and rolled back: MySQL rolls back only rows (INSERT, UPDATE, DELETE, REPLACE);
    /// its DDL commits as it runs, so it's asked untried.
    static func mayTry(_ sql: String, _ engine: DatabaseInfo.Engine) -> Bool {
        engine != .mysql || ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(verb(sql))
    }

    /// A change that can say what it changed (`RETURNING *`) when it doesn't already: an UPDATE, DELETE or INSERT, for
    /// a trial's preview. nil: leave it as it is.
    static func returning(_ statement: String) -> String? {
        guard ["UPDATE", "DELETE", "INSERT"].contains(verb(statement)),
            code(statement).range(of: #"\breturning\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return statement + "\nRETURNING *"   // a line of its own: the statement can end in a -- comment
    }
}

/// Why a statement didn't run, in words for the agent or the user.
enum DatabaseFailure: Error, Equatable {
    /// A read that would change something: the database refused it in a read-only transaction.
    case change
    case failed(String)

    var message: String {
        switch self {
        case .change: "It changes the database."
        case .failed(let text): text
        }
    }
}
