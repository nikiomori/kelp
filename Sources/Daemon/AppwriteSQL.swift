import Foundation

/// The narrow SQL Kelp speaks to Appwrite (`AppwriteWire`): what the tab writes for a page, a filter, a count and an
/// edit, and what an agent writes the same way. Anything else is said to be out of it, with what is in it.
enum AppwriteSQL {
    enum Value: Equatable {
        case text(String), number(String), bool(Bool), null
    }
    indirect enum Condition: Equatable {
        case all([Condition]), any([Condition])
        /// Appwrite's query method on a column: "equal", "contains", "isNull"…
        case test(String, String, [Value])
    }
    struct Select: Equatable {
        var table: String
        var columns: [String]?
        var count = false
        var condition: Condition?
        var orders: [(column: String, ascending: Bool)] = []
        var limit: Int?, offset: Int?

        static func == (a: Select, b: Select) -> Bool {
            a.table == b.table && a.columns == b.columns && a.count == b.count && a.condition == b.condition
                && a.orders.map(\.column) == b.orders.map(\.column)
                && a.orders.map(\.ascending)
                    == b.orders.map(\.ascending)
                && a.limit == b.limit && a.offset == b.offset
        }
    }
    struct Insert: Equatable {
        var table: String, columns: [String], rows: [[Value]]
    }
    enum Statement: Equatable {
        case select(Select), insert(Insert)
        case update(String, [(String, Value)], Condition)
        case delete(String, Condition)

        static func == (a: Statement, b: Statement) -> Bool {
            switch (a, b) {
            case (.select(let x), .select(let y)): x == y
            case (.insert(let x), .insert(let y)): x == y
            case (.update(let t, let s, let c), .update(let u, let r, let d)):
                t == u && c == d && s.map(\.0) == r.map(\.0) && s.map(\.1) == r.map(\.1)
            case (.delete(let t, let c), .delete(let u, let d)): t == u && c == d
            default: false
            }
        }
    }

    static let help =
        "Appwrite has no SQL: Kelp reads SELECT * | count(*) | columns FROM table [WHERE …] [ORDER BY …] [LIMIT n] "
        + "[OFFSET n], INSERT INTO table (…) VALUES (…), UPDATE table SET … WHERE …, DELETE FROM table WHERE …."

    static func parse(_ sql: String) throws -> Statement {
        var p = Parser(tokens: try tokens(sql))
        let statement: Statement
        if p.keyword("SELECT") {
            statement = .select(try p.select())
        } else if p.keyword("INSERT") {
            try p.expect("INTO")
            statement = .insert(try p.insert())
        } else if p.keyword("UPDATE") {
            let table = try p.name()
            try p.expect("SET")
            var set: [(String, Value)] = []
            repeat {
                let column = try p.name()
                try p.expectSymbol("=")
                set.append((column, try p.value()))
            } while p.symbol(",")
            statement = .update(table, set, try p.required())
        } else if p.keyword("DELETE") {
            try p.expect("FROM")
            let table = try p.name()
            statement = .delete(table, try p.required())
        } else {
            throw DatabaseFailure.failed(help)
        }
        guard p.done else { throw DatabaseFailure.failed(help) }
        return statement
    }

    // MARK: Words

    enum Token: Equatable {
        case word(String), name(String), text(String), number(String), symbol(String)
    }

    static func tokens(_ sql: String) throws -> [Token] {
        let s = Array(sql)
        var out: [Token] = [], i = 0
        while i < s.count {
            let c = s[i]
            if c.isWhitespace || c == ";" {
                i += 1
            } else if c == "'" || c == "\"" || c == "`" {
                var j = i + 1, text = ""
                while true {
                    guard j < s.count else { throw DatabaseFailure.failed("A quote isn't closed.") }
                    if s[j] == c {
                        guard j + 1 < s.count, s[j + 1] == c else { break }
                        j += 1
                    }
                    text.append(s[j])
                    j += 1
                }
                out.append(c == "'" ? .text(text) : .name(text))
                i = j + 1
            } else if c.isNumber || c == "-" && i + 1 < s.count && s[i + 1].isNumber {
                var j = i + 1
                while j < s.count, s[j].isNumber || s[j] == "." || s[j] == "e" || s[j] == "E" { j += 1 }
                out.append(.number(String(s[i..<j])))
                i = j
            } else if c.isLetter || c == "_" || c == "$" {
                var j = i + 1
                while j < s.count, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == "$" { j += 1 }
                out.append(.word(String(s[i..<j])))
                i = j
            } else {
                let two = i + 1 < s.count ? String(s[i...i + 1]) : ""
                let symbol = ["<>", "!=", "<=", ">=", "::"].contains(two) ? two : String(c)
                out.append(.symbol(symbol))
                i += symbol.count
            }
        }
        return out
    }

    struct Parser {
        var tokens: [Token], at = 0

        var done: Bool { at == tokens.count }
        private var next: Token? { at < tokens.count ? tokens[at] : nil }

        mutating func keyword(_ k: String) -> Bool {
            guard case .word(let w) = next, w.caseInsensitiveCompare(k) == .orderedSame else { return false }
            at += 1
            return true
        }
        mutating func symbol(_ s: String) -> Bool {
            guard next == .symbol(s) else { return false }
            at += 1
            return true
        }
        mutating func expect(_ k: String) throws {
            guard keyword(k) else { throw DatabaseFailure.failed("Expected \(k). " + AppwriteSQL.help) }
        }
        mutating func expectSymbol(_ s: String) throws {
            guard symbol(s) else { throw DatabaseFailure.failed("Expected \(s). " + AppwriteSQL.help) }
        }

        /// A table's or column's name, quoted or not; a cast after it ("::text") means nothing here.
        mutating func name() throws -> String {
            let found: String
            switch next {
            case .word(let w): found = w
            case .name(let n): found = n
            default: throw DatabaseFailure.failed("Expected a name. " + AppwriteSQL.help)
            }
            at += 1
            if symbol("::") { _ = try name() }
            return found
        }

        mutating func value() throws -> Value {
            let token = next
            at += 1
            switch token {
            case .text(let t): return .text(t)
            case .number(let n): return .number(n)
            case .word(let w) where w.uppercased() == "NULL": return .null
            case .word(let w) where w.uppercased() == "TRUE": return .bool(true)
            case .word(let w) where w.uppercased() == "FALSE": return .bool(false)
            default: throw DatabaseFailure.failed("Expected a value. " + AppwriteSQL.help)
            }
        }

        mutating func number() throws -> Int {
            guard case .number(let n) = try value(), let int = Int(n) else {
                throw DatabaseFailure.failed("Expected a number.")
            }
            return int
        }

        mutating func select() throws -> Select {
            var columns: [String]?, count = false
            if keyword("count") {
                try expectSymbol("(")
                _ = symbol("*")
                try expectSymbol(")")
                count = true
            } else if !symbol("*") {
                var names: [String] = []
                repeat { names.append(try name()) } while symbol(",")
                columns = names
            }
            try expect("FROM")
            var s = Select(table: try name(), columns: columns, count: count)
            if keyword("WHERE") { s.condition = try any() }
            if keyword("ORDER") {
                try expect("BY")
                repeat {
                    let column = try name()
                    let descending = keyword("DESC")
                    if !descending { _ = keyword("ASC") }
                    s.orders.append((column, !descending))
                } while symbol(",")
            }
            if keyword("LIMIT") { s.limit = try number() }
            if keyword("OFFSET") { s.offset = try number() }
            return s
        }

        mutating func insert() throws -> Insert {
            let table = try name()
            try expectSymbol("(")
            var columns: [String] = []
            repeat { columns.append(try name()) } while symbol(",")
            try expectSymbol(")")
            try expect("VALUES")
            var rows: [[Value]] = []
            repeat {
                try expectSymbol("(")
                var row: [Value] = []
                repeat { row.append(try value()) } while symbol(",")
                try expectSymbol(")")
                guard row.count == columns.count else {
                    throw DatabaseFailure.failed("\(columns.count) columns but \(row.count) values.")
                }
                rows.append(row)
            } while symbol(",")
            return Insert(table: table, columns: columns, rows: rows)
        }

        /// A change's WHERE: never the whole table by accident.
        mutating func required() throws -> Condition {
            guard keyword("WHERE") else {
                throw DatabaseFailure.failed("Kelp changes Appwrite's rows by a WHERE: add one (WHERE \"$id\" = '…').")
            }
            return try any()
        }

        mutating func any() throws -> Condition {
            var parts = [try all()]
            while keyword("OR") { parts.append(try all()) }
            return parts.count == 1 ? parts[0] : .any(parts)
        }

        mutating func all() throws -> Condition {
            var parts = [try atom()]
            while keyword("AND") { parts.append(try atom()) }
            return parts.count == 1 ? parts[0] : .all(parts)
        }

        mutating func atom() throws -> Condition {
            if symbol("(") {
                let inside = try any()
                try expectSymbol(")")
                return inside
            }
            let column = try name()
            if keyword("IS") {
                let not = keyword("NOT")
                try expect("NULL")
                return .test(not ? "isNotNull" : "isNull", column, [])
            }
            let not = keyword("NOT")
            if keyword("LIKE") || keyword("ILIKE") {
                guard case .text(let pattern) = try value() else { throw DatabaseFailure.failed("LIKE takes text.") }
                return Self.like(column, pattern, not: not)
            }
            if keyword("IN") {
                try expectSymbol("(")
                var values: [Value] = []
                repeat { values.append(try value()) } while symbol(",")
                try expectSymbol(")")
                return not ? .all(values.map { .test("notEqual", column, [$0]) }) : .test("equal", column, values)
            }
            if keyword("BETWEEN") {
                let low = try value()
                try expect("AND")
                return .test(not ? "notBetween" : "between", column, [low, try value()])
            }
            let methods = [
                "=": "equal", "<>": "notEqual", "!=": "notEqual", "<": "lessThan", "<=": "lessThanEqual",
                ">": "greaterThan", ">=": "greaterThanEqual"
            ]
            guard !not, case .symbol(let op) = next, let method = methods[op] else {
                throw DatabaseFailure.failed("Expected a comparison after \(column). " + AppwriteSQL.help)
            }
            at += 1
            let v = try value()
            if v == .null, method == "equal" || method == "notEqual" {
                return .test(method == "equal" ? "isNull" : "isNotNull", column, [])
            }
            return .test(method, column, [v])
        }

        /// '%a%' contains, 'a%' starts with, '%a' ends with, 'a' equals.
        static func like(_ column: String, _ pattern: String, not: Bool) -> Condition {
            let starts = pattern.hasPrefix("%"), ends = pattern.hasSuffix("%") && pattern.count > 1
            let core = String(pattern.dropFirst(starts ? 1 : 0).dropLast(ends ? 1 : 0))
            let method =
                switch (starts, ends) {
                case (true, true): not ? "notContains" : "contains"
                case (false, true): not ? "notStartsWith" : "startsWith"
                case (true, false): not ? "notEndsWith" : "endsWith"
                case (false, false): not ? "notEqual" : "equal"
                }
            return .test(method, column, [.text(core)])
        }
    }
}
