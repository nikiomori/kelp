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

    /// Writes a value for a column of this SQL type, as the schema names it. A MySQL binary column's value, which Kelp
    /// shows as hex (0x…), is written as hex, so it means those bytes; text typed there is written as text.
    public func literal(_ value: String?, type: String) -> String {
        guard self == .mysql, let value, Self.bytes(type), value.hasPrefix("0x"), value.count.isMultiple(of: 2),
            value.dropFirst(2).allSatisfy(\.isHexDigit)
        else { return literal(value) }
        return "X'" + value.dropFirst(2) + "'"
    }

    /// Whether a MySQL column of this type holds bytes: BINARY, VARBINARY, BIT or a BLOB.
    static func bytes(_ type: String) -> Bool {
        let type = type.lowercased()
        return ["binary", "varbinary", "bit"].contains { type.hasPrefix($0) } || type.hasSuffix("blob")
    }

    /// The condition that a quoted column holds a value as Kelp shows it, for a row found by all its values: "note" =
    /// 'x', or "note" IS NULL. Postgres compares the text the value's type writes (`format('%s', …)`, which is what
    /// Kelp shows), because json and xml have no "=" and a bool's `::text` is "true" where it shows "t". A MySQL FLOAT
    /// compares its text too, because '0.1' read as a double isn't the float 0.1.
    public func shows(_ column: String, _ value: String?, type: String = "") -> String {
        guard let value else { return column + " IS NULL" }
        switch self {
        case .postgres: return "format('%s', \(column)) = " + literal(value)
        case .mysql where type.lowercased().hasPrefix("float"): return "CONCAT(\(column)) = " + literal(value)
        default: return column + " = " + literal(value, type: type)
        }
    }

    /// The case-insensitive LIKE: ILIKE in Postgres. The other engines' LIKE already ignores case for text.
    public var likeAnyCase: String { self == .postgres ? "ILIKE" : "LIKE" }

    /// The prefix that makes a statement return its plan instead of running.
    public var explain: String { self == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN " }
}
