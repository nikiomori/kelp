import Foundation

// Where engines' SQL differs, said once for the app (the tab's edits, filters, plans) and kelpd (a copy's CREATE
// DATABASE): their quotes, their strings, their case-blind LIKE, their plan.

extension DatabaseInfo.Engine {
    /// A name as one SQL name: "orders", `orders` in MySQL; its own quotes doubled. A "." in it stays the name's.
    public func quoted(_ name: String) -> String {
        let quote = String(identifierQuote)
        return quote + name.replacingOccurrences(of: quote, with: quote + quote) + quote
    }

    /// A value as SQL text: NULL, or quoted ('it''s'), which every engine casts to the column's type. MySQL also reads
    /// a backslash in a string as an escape.
    public func literal(_ value: String?) -> String {
        guard var value else { return "NULL" }
        if self == .mysql { value = value.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// LIKE that doesn't mind case: Postgres' ILIKE (the others' LIKE already doesn't, for text).
    public var likeAnyCase: String { self == .postgres ? "ILIKE" : "LIKE" }

    /// What makes a statement say its plan instead of running.
    public var explain: String { self == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN " }
}
