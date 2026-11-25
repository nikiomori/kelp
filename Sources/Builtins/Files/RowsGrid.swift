import AppKit
import DesignKit

/// Rows of text (a CSV's, a chart's numbers) on the databases' grid (`GridTable`): a cell is typed over, the names
/// head the columns, a column of numbers is right-aligned in digits that line up, rows grow with Text size, and the
/// columns' widths are kept by `autosave`. A head's click sorts the rows shown, not `rows`. With no columns it says so.
@MainActor
final class RowsGrid: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = GridTable(), scroll = NSScrollView(), area = NSView()
    private let empty = EmptyStateView()
    /// The rows, the names first.
    private(set) var rows: [[String]] = []
    /// The rows in the order shown: indexes into `rows`, never the names'.
    private(set) var order: [Int] = []
    /// The columns of numbers, by index.
    private var numeric = Set<Int>()
    /// Called when a cell was typed over.
    var onEdit: () -> Void = {}

    /// `fits`: the columns share the grid's width (a sheet), rather than keeping their own and scrolling (a tab).
    init(autosave: String?, fits: Bool = false) {
        super.init()
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = fits ? .uniformColumnAutoresizingStyle : .noColumnAutoresizing
        table.gridStyleMask = []   // the rows draw the columns' lines (GridRowView)
        table.style = .plain
        table.rowHeight = TextSize.of(Metrics.row)
        table.autosaveName = autosave
        scroll.documentView = table
        scroll.automaticallyAdjustsContentInsets = false   // under the tab's bars, not the window's title
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        area.pin(scroll)
        empty.place(in: area)
    }

    /// Shows `rows`, the names first, keeping the columns when the names are the same.
    func show(_ rows: [[String]]) {
        let names = rows.first ?? []
        if names != (self.rows.first ?? []) || table.tableColumns.count != names.count {
            for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
            for (i, name) in names.enumerated() {
                let column = NSTableColumn(identifier: .init(String(i)))
                column.title = name
                column.width = Metrics.popoverWidth / 2
                column.sortDescriptorPrototype = NSSortDescriptor(key: String(i), ascending: true)
                table.addTableColumn(column)
            }
            table.autosaveTableColumns = table.autosaveName != nil   // after the columns, which it restores
            if table.columnAutoresizingStyle != .noColumnAutoresizing { table.sizeToFit() }
        }
        self.rows = rows
        numeric = Set(
            names.indices.filter { c in
                let cells = rows.dropFirst().compactMap { c < $0.count && !$0[c].isEmpty ? $0[c] : nil }
                return !cells.isEmpty && cells.allSatisfy { Double($0) != nil }
            })
        for (i, column) in table.tableColumns.enumerated() {
            column.headerCell.alignment = numeric.contains(i) ? .right : .left
        }
        order = Array(rows.indices.dropFirst())
        sort()
        empty.show(
            names.isEmpty ? String(localized: "No Columns") : nil, symbol: "tablecells",
            text: String(localized: "Its first line names the columns, separated by commas."))
    }

    /// Changes cell `column` of row `row` (an index into `rows`).
    func set(_ value: String, row: Int, column: Int) {
        guard rows.indices.contains(row) else { return }
        while rows[row].count <= column { rows[row].append("") }
        rows[row][column] = value
    }

    /// Adds an empty row at the end.
    func addRow() {
        rows.append(Array(repeating: "", count: rows.first?.count ?? 1))
        order.append(rows.count - 1)
        table.reloadData()
    }

    /// Deletes the rows shown at `shown`.
    func delete(shown: IndexSet) {
        let gone = Set(shown.compactMap { order.indices.contains($0) ? order[$0] : nil })
        rows = rows.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
        order = Array(rows.indices.dropFirst())
        sort()
    }

    /// Keeps what is being typed in a cell, when the grid is read before the cell is left.
    func commit() { table.window?.makeFirstResponder(table) }

    private func sort() {
        if let by = table.sortDescriptors.first, let c = by.key.flatMap(Int.init) {
            let cell = { (r: Int) in c < self.rows[r].count ? self.rows[r][c] : "" }
            order.sort { a, b in
                let (x, y) = (cell(a), cell(b))
                let less =
                    Double(x).flatMap { u in Double(y).map { u < $0 } }
                    ?? (x.localizedStandardCompare(y) == .orderedAscending)
                return by.ascending ? less : !less && x != y
            }
        }
        table.reloadData()
    }

    func numberOfRows(in _: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? { GridRowView() }

    /// Draws stripes only where there are rows, none past the last one, as the databases' grid does.
    func tableView(_: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.backgroundColor = row % 2 == 1 ? NSColor.alternatingContentBackgroundColors.last ?? .clear : .clear
    }

    func tableView(_: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let c = column.flatMap({ Int($0.identifier.rawValue) }), order.indices.contains(row) else { return nil }
        let cells = rows[order[row]]
        let field = NSTextField(string: c < cells.count ? cells[c] : "")
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.lineBreakMode = .byTruncatingTail
        field.font = numeric.contains(c) ? .uiDigits(TextSize.row) : .ui(TextSize.row)
        field.alignment = numeric.contains(c) ? .right : .left
        field.delegate = self
        field.tag = c
        return field
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard order.indices.contains(row) else { return }
        set(field.stringValue, row: order[row], column: field.tag)
        onEdit()
    }

    func tableView(_: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) { sort() }
}
