import AppKit
import Core
import DesignKit

/// Shows the rows of a run that changed something in the grid, with each value an update changed as it was and as it
/// becomes.
extension ResultGrid {
    /// A character's width in the cells' mono face, as Text size and the row density have it, for the column widths
    /// estimated from the values' lengths.
    var charWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }

    /// Marks the rows as a change's. The columns that changed (`changed`, by index) widen to hold both values.
    func show(change: RowChange?, changed: [Int]) {
        self.change = change
        for column in table.tableColumns {
            guard let index = Int(column.identifier.rawValue), changed.contains(index), let before = change?.before
            else { continue }
            let was = before.prefix(60).map { ($0.indices.contains(index) ? $0[index] : nil)?.count ?? 4 }.max() ?? 0
            column.width = min(480, column.width + CGFloat(was + 3) * charWidth)
        }
        table.reloadData()
    }

    /// The row's number, with a mark before it of what saving does to it, so it isn't told by its colour alone:
    /// • edited, − deleted, and + for a new row in place of a number.
    func number(_ row: Int, new: Bool) -> NSAttributedString {
        let mark = edits.deleted.contains(row) ? "− " : edits.cells[row] != nil ? "• " : ""
        // An attributed string keeps its own alignment, so the field's `.right` doesn't reach it.
        return NSAttributedString(
            string: new ? "+" : mark + String(row + 1),
            attributes: [
                .font: NSFont.uiDigits(TextSize.caption), .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: Self.aligned(.right)
            ])
    }

    /// What VoiceOver says of a row's number: the row, and what is to happen to it or what an agent did.
    func rowName(_ row: Int) -> String {
        if row >= rows.count { return String(localized: "New row") }
        let number = String(row + 1)
        if edits.deleted.contains(row) || change?.kind == .delete {
            return String(localized: "Row \(number), to be deleted")
        }
        if edits.cells[row] != nil { return String(localized: "Row \(number), changed") }
        if marked.contains(row) { return String(localized: "Row \(number), changed by an agent") }
        return String(localized: "Row \(number)")
    }

    /// Shows a cell an update changed as "was → becomes"; returns false when the cell isn't one.
    func showChange(_ value: String?, in field: NSTextField, row: Int, column: Int) -> Bool {
        guard let was = change?.before, was.indices.contains(row), was[row].indices.contains(column),
            was[row][column] != value
        else { return false }
        field.attributedStringValue = .change(from: was[row][column], to: value, font: font)
        field.toolTip = [was[row][column] ?? "NULL", value ?? "NULL"].joined(separator: "\n→ ")
        return true
    }
}
