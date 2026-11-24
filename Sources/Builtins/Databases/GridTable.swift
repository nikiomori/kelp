import AppKit

/// The grid's table: Space shows the row, ⌫ marks the selected rows to be deleted, and ⌘C / ⌘V copy and paste
/// (`ResultGrid.copySelection`, `paste`). It keeps the cell last clicked, the one being looked at, while its row is
/// the one selected.
final class GridTable: NSTableView {
    var onSpace: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    /// The row and the result's column (the numbers' column isn't one) of the cell clicked last.
    var lookedAt: (row: Int, column: Int)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49 where event.modifierFlags.isDisjoint(with: [.command, .option, .control]): onSpace()
        case 51, 117: onDelete()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        let row = row(at: at), index = column(at: at)
        let column = tableColumns.indices.contains(index) ? Int(tableColumns[index].identifier.rawValue) : nil
        lookedAt = row >= 0 ? column.map { (row, $0) } : nil
        super.mouseDown(with: event)
    }

    /// The cell being looked at: the one clicked last, while its row is the only one selected.
    var cellLookedAt: (row: Int, column: Int)? {
        guard let lookedAt, selectedRowIndexes == [lookedAt.row] else { return nil }
        return lookedAt
    }

    @objc func copy(_ sender: Any?) { onCopy() }
    @objc func paste(_ sender: Any?) { onPaste() }
}
