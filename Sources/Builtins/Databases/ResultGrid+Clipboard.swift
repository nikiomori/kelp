import AppKit
import DesignKit

/// ⌘C and ⌘V in the grid. ⌘C copies the cell being looked at (`GridTable.cellLookedAt`), as Copy Value does, or
/// else the selected rows as TSV with their header, as Copy Rows As › TSV does. ⌘V puts TSV (a spreadsheet's, or the
/// grid's own) into the cells from there on as edits, which Save saves: NULL is NULL, a line past the rows adds a row.
extension ResultGrid {
    func copySelection() {
        if let cell = table.cellLookedAt, rows.indices.contains(cell.row), rows[cell.row].indices.contains(cell.column)
        {
            return copyText(rows[cell.row][cell.column] ?? "NULL")
        }
        let picked = selectedRows
        guard !picked.isEmpty else { return NSSound.beep() }
        copyText(text(picked))
    }

    func pasteFromClipboard() {
        guard editable, source != nil, let text = NSPasteboard.general.string(forType: .string) else {
            return NSSound.beep()
        }
        paste(text)
    }

    /// Puts TSV into the cells from the cell being looked at (else the first selected row's first column) on, as
    /// edits. The grid's own header line, when copied with the rows, is left out.
    func paste(_ text: String) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        if lines.first == columns.joined(separator: "\t") { lines.removeFirst() }
        guard !lines.isEmpty, let start = table.cellLookedAt ?? table.selectedRowIndexes.first.map({ ($0, 0) }) else {
            return NSSound.beep()
        }
        for (offset, line) in lines.enumerated() {
            let values = line.components(separatedBy: "\t").map { $0 == "NULL" ? nil : $0 }
            let row = start.row + offset
            if row >= count { edits.add(Array(repeating: nil, count: columns.count)) }
            for (index, value) in values.enumerated() where columns.indices.contains(start.column + index) {
                set(row: row, column: start.column + index, to: value)
            }
        }
        changed()
        table.selectRowIndexes(IndexSet(start.row..<start.row + lines.count), byExtendingSelection: false)
    }

    /// Sets one cell's value as an edit: a read row's against the value read, a new row's as typed.
    func set(row: Int, column: Int, to value: String?) {
        if row >= rows.count {
            edits.setAdded(row - rows.count, column: column, to: value)
        } else if rows[row].indices.contains(column) {
            edits.set(row: row, column: column, to: value, was: rows[row][column])
        }
    }
}
