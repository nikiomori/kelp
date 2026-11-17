import AppKit
import Core
import DesignKit

/// The rows of a run that changed something, in the grid: each value an update changed, as it was and as it becomes.
extension ResultGrid {
    /// The rows are a change's: its columns that changed (`changed`, by index) widen to hold both values.
    func show(change: RowChange?, changed: [Int]) {
        self.change = change
        for column in table.tableColumns {
            guard let index = Int(column.identifier.rawValue), changed.contains(index), let before = change?.before
            else { continue }
            let was = before.prefix(60).map { ($0.indices.contains(index) ? $0[index] : nil)?.count ?? 4 }.max() ?? 0
            column.width = min(480, column.width + CGFloat(was + 3) * 7.2)
        }
        table.reloadData()
    }

    /// A cell an update changed, shown as "was → becomes"; false when it isn't one.
    func showChange(_ value: String?, in field: NSTextField, row: Int, column: Int) -> Bool {
        guard let was = change?.before, was.indices.contains(row), was[row].indices.contains(column),
            was[row][column] != value
        else { return false }
        field.attributedStringValue = .change(from: was[row][column], to: value, font: font)
        field.toolTip = [was[row][column] ?? "NULL", value ?? "NULL"].joined(separator: "\n→ ")
        return true
    }
}
