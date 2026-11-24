import AppKit
import Core
import KelpKit
import os

/// A table's columns as the user left them (`ColumnsLook`), kept per database and table in Kelp's state
/// ("db.columns/<project>/<database>/<table>"): opened again, in this tab or another, the table has them back.
extension DatabaseTab {
    private func lookKey(_ table: String) -> String { key("columns") + "/" + table }

    /// Keeps the look of the table whose data shows.
    func keepLook() {
        guard let table = grid.source?.table, mode.table == table, !grid.columns.isEmpty,
            let look = Self.log.attempt("keeping columns", { try JSONValue.from(grid.look) })
        else { return }
        app.uiState[lookKey(table)] = look
    }

    func keptLook(_ table: String) -> ColumnsLook? {
        guard let kept = app.uiState[lookKey(table)] else { return nil }
        return Self.log.attempt("reading columns") { try kept.decode(ColumnsLook.self) }
    }

    private static let log = Logger.kelp("databases")

    /// The order a table's rows were read in last.
    func keptOrder(_ table: String) -> [(column: String, ascending: Bool)] {
        keptLook(table)?.orders.map { ($0.column, $0.ascending) } ?? []
    }
}
