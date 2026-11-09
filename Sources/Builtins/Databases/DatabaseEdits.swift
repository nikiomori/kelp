import Core
import Foundation

/// Cells the user changed in a table's rows, and the statements that save them: an UPDATE per row, found by its
/// primary key's values as they were read.
struct DatabaseEdits: Equatable {
    /// The new value by row and column (nil: NULL).
    private(set) var cells: [Int: [Int: String?]] = [:]

    var count: Int { cells.values.map(\.count).reduce(0, +) }
    var isEmpty: Bool { cells.isEmpty }

    func edited(row: Int, column: Int) -> Bool { cells[row]?[column] != nil }
    func value(row: Int, column: Int) -> String?? { cells[row]?[column] }

    /// A value typed over the one read; typing the old value back drops the edit.
    mutating func set(row: Int, column: Int, to value: String?, was old: String?) {
        if value == old {
            cells[row]?[column] = nil
            if cells[row]?.isEmpty == true { cells[row] = nil }
        } else {
            cells[row, default: [:]][column] = .some(value)
        }
    }

    mutating func clear() { cells = [:] }

    /// One UPDATE a row, in row order; nil when a row can't be told apart (no primary key among the columns).
    func statements(
        table: String, engine: DatabaseInfo.Engine, columns: [String], primary: [String], rows: [[String?]]
    ) -> [String]? {
        let keys = primary.compactMap { columns.firstIndex(of: $0) }
        guard !keys.isEmpty, keys.count == primary.count else { return nil }
        return cells.keys.sorted().compactMap { row in
            guard rows.indices.contains(row), let changed = cells[row] else { return nil }
            let set = changed.keys.sorted().map { column in
                "\(Self.name(columns[column], engine)) = \(Self.literal(changed[column] ?? nil, engine))"
            }
            let match = keys.map { key in
                let old = rows[row][key]
                return "\(Self.name(columns[key], engine)) "
                    + (old == nil ? "IS NULL" : "= \(Self.literal(old, engine))")
            }
            return "UPDATE \(Self.name(table, engine)) SET \(set.joined(separator: ", ")) WHERE "
                + match.joined(separator: " AND ")
        }
    }

    /// A table or column name, quoted for the engine: "orders", `orders` in MySQL; "public.orders" as two parts.
    static func name(_ name: String, _ engine: DatabaseInfo.Engine) -> String {
        let quote: Character = engine == .mysql ? "`" : "\""
        return name.split(separator: ".").map { part in
            String(quote) + part.replacingOccurrences(of: String(quote), with: String(quote) + String(quote))
                + String(quote)
        }.joined(separator: ".")
    }

    /// A value as SQL text: NULL, or quoted ('it''s'), which every engine casts to the column's type. MySQL also reads
    /// a backslash in a string as an escape.
    static func literal(_ value: String?, _ engine: DatabaseInfo.Engine) -> String {
        guard var value else { return "NULL" }
        if engine == .mysql { value = value.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
