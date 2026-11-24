import Core
import Foundation

/// The user's changes to a table's rows, and the statements that save them. Each edited row gets an UPDATE and each
/// deleted row a DELETE, which find the row by its primary key's values as they were read. With no key they match all
/// the row's values and touch only one such row. Each new row gets an INSERT.
struct DatabaseEdits: Equatable {
    /// The new value by row and column (nil: NULL).
    private(set) var cells: [Int: [Int: String?]] = [:]
    /// Rows added at the end, with a value per column (nil leaves it to the database's default).
    private(set) var added: [[String?]] = []
    /// Rows that were read and are to be deleted.
    private(set) var deleted = Set<Int>()

    var count: Int { cells.values.map(\.count).reduce(0, +) + added.count + deleted.count }
    var isEmpty: Bool { cells.isEmpty && added.isEmpty && deleted.isEmpty }

    func edited(row: Int, column: Int) -> Bool { cells[row]?[column] != nil }
    func value(row: Int, column: Int) -> String?? { cells[row]?[column] }

    /// Records a value typed over the one that was read; typing the old value back drops the edit.
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

    /// Marks a row deleted and drops its edits. Deleting a row that is already marked deleted keeps the row after all.
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

    /// Returns the deletes, then the updates, then the inserts, each in row order.
    /// `types` holds each column's type as the schema names it, for the values whose SQL depends on it
    /// (`DatabaseInfo.Engine.literal(_:type:)`, `shows`).
    func statements(
        table: String, engine: DatabaseInfo.Engine, columns: [String], primary: [String], rows: [[String?]],
        types: [String: String] = [:]
    ) -> [String] {
        let primaries = primary.compactMap { columns.firstIndex(of: $0) }
        let keyed = !primaries.isEmpty && primaries.count == primary.count
        let keys = keyed ? primaries : Array(columns.indices)
        let name = Self.name(table, engine)
        func literal(_ value: String?, _ column: Int) -> String {
            engine.literal(value, type: types[columns[column]] ?? "")
        }
        func match(_ row: Int) -> String {
            keys.map { key in
                let old = rows[row][key], column = Self.name(columns[key], engine)
                // Without a key every column is compared, as Kelp shows it (json has no "=", a bool shows as "t")
                if !keyed { return engine.shows(column, old, type: types[columns[key]] ?? "") }
                return column + (old == nil ? " IS NULL" : " = \(literal(old, key))")
            }.joined(separator: " AND ")
        }
        // Limit: rows are told apart by their values, so of two identical rows either one goes.
        // CockroachDB has no ctid.
        func one(_ row: Int) -> String {
            if keyed { return " WHERE " + match(row) }
            switch engine {
            case .mysql, .appwrite: return " WHERE " + match(row) + " LIMIT 1"   // an Appwrite row always has its $id
            case .postgres:
                // ctid is unique within one table only, and a partitioned or inherited table has a row with that ctid
                // in each part, so tableoid is matched too.
                return " WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM \(name) WHERE \(match(row)) LIMIT 1)"
            case .sqlite, .duckdb: return " WHERE rowid = (SELECT rowid FROM \(name) WHERE \(match(row)) LIMIT 1)"
            }
        }
        let deletes = deleted.sorted().filter { rows.indices.contains($0) }.map { "DELETE FROM \(name)" + one($0) }
        let updates = cells.keys.sorted().compactMap { row -> String? in
            guard rows.indices.contains(row), let changed = cells[row], !deleted.contains(row) else { return nil }
            let set = changed.keys.sorted().map { column in
                "\(Self.name(columns[column], engine)) = \(literal(changed[column] ?? nil, column))"
            }
            return "UPDATE \(name) SET \(set.joined(separator: ", "))" + one(row)
        }
        let inserts = added.compactMap { row -> String? in
            let given = row.indices.filter { row[$0] != nil && columns.indices.contains($0) }
            guard !given.isEmpty else { return nil }
            return "INSERT INTO \(name) (" + given.map { Self.name(columns[$0], engine) }.joined(separator: ", ")
                + ") VALUES (" + given.map { literal(row[$0], $0) }.joined(separator: ", ") + ")"
        }
        return deletes + updates + inserts
    }

    /// Quotes a table or column name for the engine (`DatabaseInfo.Engine.table`).
    static func name(_ name: String, _ engine: DatabaseInfo.Engine) -> String { engine.table(name) }
}
