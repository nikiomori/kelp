import AppKit
import Core
import DesignKit
import KelpKit

/// Rows as a grid: a column a result column, NULL in grey, numbers in digits that line up. Cells can be edited when
/// `editable` (a table's rows with a primary key): an edit is kept in `edits` and shown on its cell until saved.
@MainActor
final class ResultGrid: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let scroll = NSScrollView()
    private let table = NSTableView()
    private(set) var columns: [String] = []
    private(set) var rows: [[String?]] = []
    var edits = DatabaseEdits()
    var editable = false
    /// An edit was made or undone, or the selection changed.
    var onChange: () -> Void = {}
    /// Rows a table shows at most: past them the grid says how many more.
    static let shown = 1000

    override init() {
        super.init()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.style = .plain
        table.rowHeight = TextSize.of(22)
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
    }

    var selectedRows: [Int] { table.selectedRowIndexes.filter { rows.indices.contains($0) } }

    func show(columns: [String], rows: [[String?]]) {
        self.columns = columns
        self.rows = rows
        edits.clear()
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        let index = NSTableColumn(identifier: .init("#"))
        index.width = 40
        index.title = ""
        table.addTableColumn(index)
        for (i, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.title = name
            column.headerToolTip = name
            let longest = rows.prefix(60).map { ($0.indices.contains(i) ? $0[i] : nil)?.count ?? 4 }.max() ?? 0
            column.width = min(320, max(60, CGFloat(max(longest, name.count)) * 7 + 16))
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Asked for an old row while the columns change over to another result.
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        guard let column = Int(id) else {   // the row's number
            field.stringValue = String(row + 1)
            field.font = .uiDigits(11)
            field.textColor = .tertiaryLabelColor
            field.alignment = .right
            return field
        }
        let read = rows[row].indices.contains(column) ? rows[row][column] : nil
        let value = edits.value(row: row, column: column) ?? read
        if let value {
            field.stringValue = value.replacingOccurrences(of: "\n", with: "⏎")
            field.font = Double(value) != nil ? .uiDigits(12) : .ui(12)
            field.alignment = Double(value) != nil ? .right : .left
            field.toolTip = value.count > 40 ? value : nil
        } else {
            field.stringValue = "NULL"
            field.font = .ui(12)
            field.textColor = .tertiaryLabelColor
        }
        if editable {
            field.isEditable = true
            field.delegate = self
            field.tag = column
        }
        if edits.edited(row: row, column: column) {
            field.drawsBackground = true
            field.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25)
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onChange() }

    /// An edit ends: kept, unless it's the value read (an empty field over NULL is no change).
    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField else { return }
        let row = table.row(for: field), column = field.tag
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        let old = rows[row][column], typed = field.stringValue
        let value: String? = old == nil && typed.isEmpty || typed == "NULL" && old == nil ? nil : typed
        edits.set(row: row, column: column, to: value, was: old)
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        onChange()
    }

    func discard() {
        edits.clear()
        table.reloadData()
        onChange()
    }

    /// The selected rows as text with a header, tab between cells: for the clipboard and for an agent.
    func text(_ rows: [Int]) -> String {
        ([columns.joined(separator: "\t")] + rows.map { self.rows[$0].map { $0 ?? "NULL" }.joined(separator: "\t") })
            .joined(separator: "\n")
    }
}

extension ResultGrid: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow, column = table.clickedColumn - 1   // the first column is the rows' numbers
        guard rows.indices.contains(row) else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let picked = selectedRows
        menu.add(String(localized: "Copy Rows")) { [weak self] in
            if let self { copyText(text(picked)) }
        }
        if rows[row].indices.contains(column) {
            let value = rows[row][column]
            menu.add(String(localized: "Copy Value")) { copyText(value ?? "NULL") }
            if editable, value != nil || edits.edited(row: row, column: column) {
                menu.add(String(localized: "Set to NULL")) { [weak self] in
                    guard let self else { return }
                    edits.set(row: row, column: column, to: nil, was: value)
                    table.reloadData()
                    onChange()
                }
            }
        }
    }
}
