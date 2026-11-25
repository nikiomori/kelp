import Foundation

/// What makes an agent's change worth a second look before Allow (`QueryResult.risk`): the card that asks says it in
/// a line of its own. Only these kinds have one; a plain change has none, so the line isn't read past.
public struct ChangeRisk: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// An UPDATE or DELETE with no WHERE: every row of `table` changes.
        case noWhere
        /// A DROP of `table` (or of the index, view… it names), or a TRUNCATE of it: its `values` rows go.
        case drop, truncate
        /// An ALTER TABLE that drops `column`: its `values` values go.
        case dropColumn
        /// A row change that Undo This Change in History couldn't put back.
        case noUndo
    }
    public var kind: Kind
    /// The table (or what is dropped) as the statement names it, quotes included.
    public var table: String
    public var column: String?
    /// How many rows (or a column's values that aren't NULL) go, when Kelp counted them.
    public var values: Int?
    public init(kind: Kind, table: String, column: String? = nil, values: Int? = nil) {
        self.kind = kind
        self.table = table
        self.column = column
        self.values = values
    }

    /// The table's name without its quotes, for use in sentences.
    public var tableName: String { table.filter { !"\"`".contains($0) } }
    public var columnName: String? { column?.filter { !"\"`".contains($0) } }
}

extension RowChange {
    /// Whether Undo This Change can put the rows back: each can be found by the table's key, and an update's rows were
    /// kept as they were.
    public var undoable: Bool { !key.isEmpty && (kind != .update || before != nil) }
}
