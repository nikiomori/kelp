import AppKit

/// A grid's table (a database's rows, a CSV, a chart's numbers): Space shows the row, ⌫ marks the selected rows to be
/// deleted, ⌥↩ opens a cell's value in a sheet (`ResultGrid.openSelected`), and a cell whose value opens there isn't
/// typed in. ⌘C / ⌘V copy and paste (`ResultGrid.copySelection`, `paste`). It keeps the cell last clicked, the one
/// being looked at, while its row is the one selected.
@MainActor
public final class GridTable: NSTableView {
    public var onSpace: () -> Void = {}
    public var onDelete: () -> Void = {}
    public var onCopy: () -> Void = {}
    public var onPaste: () -> Void = {}
    public var onOpen: () -> Void = {}
    public var opensInSheet: (_ row: Int, _ column: Int) -> Bool = { _, _ in false }
    /// The row and the result's column (the numbers' column isn't one) of the cell clicked last.
    public var lookedAt: (row: Int, column: Int)?

    override public func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49 where event.modifierFlags.isDisjoint(with: [.command, .option, .control]): onSpace()
        case 51, 117: onDelete()
        case 36 where event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option: onOpen()
        default: super.keyDown(with: event)
        }
    }

    override public func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        let row = row(at: at), index = column(at: at)
        let column = tableColumns.indices.contains(index) ? Int(tableColumns[index].identifier.rawValue) : nil
        lookedAt = row >= 0 ? column.map { (row, $0) } : nil
        super.mouseDown(with: event)
    }

    /// The cell being looked at: the one clicked last, while its row is the only one selected.
    public var cellLookedAt: (row: Int, column: Int)? {
        guard let lookedAt, selectedRowIndexes == [lookedAt.row] else { return nil }
        return lookedAt
    }

    /// A cell whose value opens in the sheet takes no typing: its double click opens the sheet instead.
    override public func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable {
            let row = row(for: field), index = column(for: field)
            if row >= 0, tableColumns.indices.contains(index),
                let column = Int(tableColumns[index].identifier.rawValue),
                opensInSheet(row, column)
            {
                return false
            }
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    /// Nor does moving into it with Tab.
    override public func editColumn(_ column: Int, row: Int, with event: NSEvent?, select: Bool) {
        if tableColumns.indices.contains(column), let index = Int(tableColumns[column].identifier.rawValue),
            opensInSheet(row, index)
        {
            return
        }
        super.editColumn(column, row: row, with: event, select: select)
    }

    @objc public func copy(_ sender: Any?) { onCopy() }
    @objc public func paste(_ sender: Any?) { onPaste() }
}
