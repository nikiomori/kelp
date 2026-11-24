import Foundation

// The places where the engines' SQL differs, written once for both the app (the tab's edits, filters, plans) and kelpd
// (a copy's CREATE DATABASE). They are the quotes, the strings, the case-insensitive LIKE and the plan.

extension DatabaseInfo.Engine {
    /// Quotes a name as a single SQL name: "orders", or `orders` in MySQL, with any quotes inside it doubled. A "." in
    /// the name stays part of the name.
    public func quoted(_ name: String) -> String {
        let quote = String(identifierQuote)
        return quote + name.replacingOccurrences(of: quote, with: quote + quote) + quote
    }

    /// Quotes a table's name as the schema lists it. Postgres names a table outside public with its schema
    /// ("audit.orders"), so the name has two parts. In other engines a "." is part of the name itself.
    public func table(_ name: String) -> String {
        let parts = self == .postgres ? name.split(separator: ".", maxSplits: 1).map(String.init) : [name]
        return parts.map(quoted).joined(separator: ".")
    }

    /// Writes a value as SQL text: NULL, or a quoted string ('it''s') that every engine casts to the column's type.
    /// MySQL also reads a backslash in a string as an escape.
    public func literal(_ value: String?) -> String {
        guard var value else { return "NULL" }
        if self == .mysql { value = value.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The case-insensitive LIKE: ILIKE in Postgres. The other engines' LIKE already ignores case for text.
    public var likeAnyCase: String { self == .postgres ? "ILIKE" : "LIKE" }

    /// The prefix that makes a statement return its plan instead of running.
    public var explain: String { self == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN " }
}
