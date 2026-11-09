import Core
import Foundation

/// What the user changed in a table's rows, and the statements that save it: an UPDATE per edited row and a DELETE per
/// deleted one, each found by its primary key's values as they were read (with no key, by all its values, and only one
/// such row touched); an INSERT per new row.
struct DatabaseEdits: Equatable {
    /// The new value by row and column (nil: NULL).
    private(set) var cells: [Int: [Int: String?]] = [:]
    /// Rows added at the end: a value per column (nil: left to the database's default).
    private(set) var added: [[String?]] = []
    /// Rows read that are to go.
    private(set) var deleted = Set<Int>()

    var count: Int { cells.values.map(\.count).reduce(0, +) + added.count + deleted.count }
    var isEmpty: Bool { cells.isEmpty && added.isEmpty && deleted.isEmpty }

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

    mutating func add(_ row: [String?]) { added.append(row) }
    mutating func setAdded(_ index: Int, column: Int, to value: String?) {
        guard added.indices.contains(index), added[index].indices.contains(column) else { return }
        added[index][column] = value
    }
    mutating func removeAdded(_ index: Int) { if added.indices.contains(index) { added.remove(at: index) } }

    /// Deleting a row marked deleted keeps it.
    mutating func toggleDeleted(_ row: Int) {
        if deleted.remove(row) == nil {
            deleted.insert(row)
            cells[row] = nil
        }
    }

    mutating func clear() {
        cells = [:]
        added = []
        deleted = []
    }

    /// Deletes, then updates, then inserts, in row order.
    func statements(
        table: String, engine: DatabaseInfo.Engine, columns: [String], primary: [String], rows: [[String?]]
    ) -> [String] {
        let primaries = primary.compactMap { columns.firstIndex(of: $0) }
        let keyed = !primaries.isEmpty && primaries.count == primary.count
        let keys = keyed ? primaries : Array(columns.indices)
        let name = Self.name(table, engine)
        func match(_ row: Int) -> String {
            keys.map { key in
                let old = rows[row][key]
                // Without a key every column is compared, as text in Postgres (json has no "=")
                let column = Self.name(columns[key], engine) + (!keyed && engine == .postgres ? "::text" : "")
                return column + (old == nil ? " IS NULL" : " = \(Self.literal(old, engine))")
            }.joined(separator: " AND ")
        }
        // ponytail: rows told apart by their values; two identical rows are one (either goes). CockroachDB has no ctid.
        func one(_ row: Int) -> String {
            if keyed { return " WHERE " + match(row) }
            switch engine {
            case .mysql, .appwrite: return " WHERE " + match(row) + " LIMIT 1"   // Appwrite always has its $id
            case .postgres:
                // ctid is unique within one table only: a partitioned or inherited one has a row of that ctid in each
                return " WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM \(name) WHERE \(match(row)) LIMIT 1)"
            case .sqlite, .duckdb: return " WHERE rowid = (SELECT rowid FROM \(name) WHERE \(match(row)) LIMIT 1)"
            }
        }
        let deletes = deleted.sorted().filter { rows.indices.contains($0) }.map { "DELETE FROM \(name)" + one($0) }
        let updates = cells.keys.sorted().compactMap { row -> String? in
            guard rows.indices.contains(row), let changed = cells[row], !deleted.contains(row) else { return nil }
            let set = changed.keys.sorted().map { column in
                "\(Self.name(columns[column], engine)) = \(Self.literal(changed[column] ?? nil, engine))"
            }
            return "UPDATE \(name) SET \(set.joined(separator: ", "))" + one(row)
        }
        let inserts = added.compactMap { row -> String? in
            let given = row.indices.filter { row[$0] != nil && columns.indices.contains($0) }
            guard !given.isEmpty else { return nil }
            return "INSERT INTO \(name) (" + given.map { Self.name(columns[$0], engine) }.joined(separator: ", ")
                + ") VALUES (" + given.map { Self.literal(row[$0], engine) }.joined(separator: ", ") + ")"
        }
        return deletes + updates + inserts
    }

    /// A table or column name, quoted for the engine: "orders", `orders` in MySQL. Postgres names a table outside
    /// public by its schema ("audit.orders", as its schema lists it): two parts; elsewhere a "." is the name's own.
    static func name(_ name: String, _ engine: DatabaseInfo.Engine) -> String {
        let quote: Character = engine == .mysql ? "`" : "\""
        let parts = engine == .postgres ? name.split(separator: ".", maxSplits: 1).map(String.init) : [name]
        return parts.map { part in
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
