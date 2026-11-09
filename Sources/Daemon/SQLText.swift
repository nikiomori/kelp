import Foundation

/// SQL as text: its statements, and what kind the first one is. Quotes ('…', "…", `…`, $tag$…$tag$) and comments
/// (-- …, /* … */) are skipped, so a ";" inside them doesn't split.
enum SQLText {
    /// The statements, each trimmed, empty ones (a trailing ";", only a comment) dropped.
    static func statements(_ sql: String) -> [String] {
        let chars = Array(sql)
        var parts: [String] = [], start = 0, i = 0
        func skip(to end: String, from index: Int) -> Int {
            let target = Array(end)
            var j = index
            while j < chars.count {
                if Array(chars[j..<min(j + target.count, chars.count)]) == target { return j + target.count }
                j += 1
            }
            return chars.count
        }
        while i < chars.count {
            let c = chars[i], next = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "'", "\"", "`":
                var j = i + 1
                while j < chars.count {
                    if chars[j] == c {
                        if j + 1 < chars.count, chars[j + 1] == c {
                            j += 2   // '' inside a string
                            continue
                        }
                        break
                    }
                    if chars[j] == "\\", c != "\"", j + 1 < chars.count { j += 1 }   // MySQL's \' (harmless elsewhere)
                    j += 1
                }
                i = j + 1
            case "-" where next == "-": i = skip(to: "\n", from: i + 2)
            case "#" where i == 0 || chars[i - 1].isNewline: i = skip(to: "\n", from: i + 1)
            case "/" where next == "*": i = skip(to: "*/", from: i + 2)
            case "$":
                // $$ or $tag$: a Postgres dollar-quoted string, to the same tag.
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                if j < chars.count, chars[j] == "$" {
                    i = skip(to: String(chars[i...j]), from: j + 1)
                } else {
                    i += 1
                }
            case ";":
                parts.append(String(chars[start..<i]))
                start = i + 1
                i += 1
            default: i += 1
            }
        }
        if start < chars.count { parts.append(String(chars[start...])) }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !code($0).isEmpty }
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

    /// The one statement a call may run: more, or a client command (psql's \…), is refused before anything runs. One at
    /// a
    /// time keeps a read-only transaction whole (a "COMMIT; DELETE …" would leave it) and what the user allows all that
    /// runs.
    static func single(_ sql: String) throws -> String {
        let all = statements(sql)
        guard let only = all.first else { throw DatabaseFailure.failed("There's no statement to run.") }
        guard all.count == 1 else {
            throw DatabaseFailure.failed("One statement at a time: this has \(all.count). Run them one by one.")
        }
        guard !code(only).hasPrefix("\\") else {
            throw DatabaseFailure.failed("That's a psql command, not SQL: Kelp runs SQL only.")
        }
        return only
    }

    /// A change that can say what it changed (`RETURNING *`) when it doesn't already: an UPDATE, DELETE or INSERT, for
    /// a trial's preview. nil: leave it as it is.
    static func returning(_ statement: String) -> String? {
        guard ["UPDATE", "DELETE", "INSERT"].contains(verb(statement)),
            code(statement).range(of: #"\breturning\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return statement + " RETURNING *"
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
