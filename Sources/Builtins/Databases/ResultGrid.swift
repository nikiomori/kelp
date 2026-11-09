import AppKit
import Core
import DesignKit
import KelpKit

/// A row of the grid: its stripe, and the columns' lines, drawn by the row so there are none under the last one.
final class GridRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let table = superview as? NSTableView else { return }
        NSColor.separatorColor.setFill()
        for column in 0..<table.numberOfColumns {
            NSRect(x: table.rect(ofColumn: column).maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

/// The grid's table: Space shows the row, ⌫ marks the selected rows to go.
final class GridTable: NSTableView {
    var onSpace: () -> Void = {}
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49 where event.modifierFlags.isDisjoint(with: [.command, .option, .control]): onSpace()
        case 51, 117: onDelete()
        default: super.keyDown(with: event)
        }
    }
}

/// Rows as a grid: a column a result column, its type and keys in the header when the table's known; NULL in grey,
/// numbers in digits that line up; stripes only where there are rows. A table with a primary key can be edited: cells
/// typed over, rows added at the end (green) or marked to go (red), all kept in `edits` until saved. Rows an agent's
/// last change touched carry its mark in the numbers' column. A header click asks for that order (`onSort`).
@MainActor
final class ResultGrid: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let scroll = NSScrollView()
    let table = GridTable()
    private(set) var columns: [String] = []
    private(set) var rows: [[String?]] = []
    /// The table's columns by name, when the rows are a table's: types and keys for the header.
    private(set) var info: [String: DatabaseSchema.Column] = [:]
    var edits = DatabaseEdits()
    var editable = false
    /// Rows an agent's last change touched (by index), and that agent's colour.
    var marked = Set<Int>()
    var markColor = NSColor.systemOrange
    /// The order asked for: a column and whether it goes up.
    var order: (column: String, ascending: Bool)?
    /// An edit was made or undone, or the selection changed.
    var onChange: () -> Void = {}
    /// A header was clicked: the order to read the rows in next (nil: as they come).
    var onSort: ((String, Bool)?) -> Void = { _ in }
    /// "Rows Where …" from a cell's menu: a WHERE condition.
    var onFilter: (String) -> Void = { _ in }
    /// The table and engine the rows are of, for Copy as INSERT and the filters' quoting.
    var source: (table: String, engine: DatabaseInfo.Engine)?
    /// Rows a table shows at most.
    static let shown = 1000

    override init() {
        super.init()
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = []   // the rows draw the columns' lines (GridRowView)
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
    /// All rows shown: those read, then those added.
    var count: Int { rows.count + edits.added.count }

    func show(columns: [String], rows: [[String?]], info: [DatabaseSchema.Column] = []) {
        self.columns = columns
        self.rows = rows
        self.info = Dictionary(info.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        edits.clear()
        marked = []
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        let index = NSTableColumn(identifier: .init("#"))
        index.width = 44
        index.title = ""
        table.addTableColumn(index)
        for (i, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.headerCell.attributedStringValue = header(name)
            column.headerToolTip = describe(name)
            let longest = rows.prefix(60).map { ($0.indices.contains(i) ? $0[i] : nil)?.count ?? 4 }.max() ?? 0
            let type = self.info[name].map { $0.type.count + 2 } ?? 0
            column.width = min(320, max(60, CGFloat(max(longest, name.count + type)) * 7 + 22))
            column.minWidth = 40
            table.addTableColumn(column)
        }
        indicate()
        table.reloadData()
    }

    /// "id int8 ⚿", "user_id int8 → users": the name, then its type and keys quieter.
    private func header(_ name: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: name, attributes: [.font: NSFont.ui(11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        guard let c = info[name] else { return text }
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.ui(10), .foregroundColor: NSColor.tertiaryLabelColor]
        text.append(NSAttributedString(string: " " + c.type.lowercased(), attributes: quiet))
        if c.primary {
            let key = NSImage.symbol("key.fill", String(localized: "primary key"))
            let mark = NSTextAttachment()
            mark.image = key.withSymbolConfiguration(
                .init(pointSize: 8, weight: .regular).applying(.init(hierarchicalColor: .systemOrange)))
            text.append(NSAttributedString(string: " ", attributes: quiet))
            text.append(NSAttributedString(attachment: mark))
        }
        if let ref = c.references {
            text.append(
                NSAttributedString(
                    string: " → " + (ref.split(separator: ".").first.map(String.init) ?? ref), attributes: quiet))
        }
        return text
    }

    private func describe(_ name: String) -> String {
        guard let c = info[name] else { return name }
        return [
            "\(name): \(c.type)", c.nullable ? nil : "NOT NULL", c.primary ? String(localized: "primary key") : nil,
            c.references.map { String(localized: "refers to \($0)") }
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func indicate() {
        for column in table.tableColumns {
            let name = Int(column.identifier.rawValue).flatMap { columns.indices.contains($0) ? columns[$0] : nil }
            let image = order.flatMap { o in
                name == o.column
                    ? NSImage(named: o.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
            }
            table.setIndicatorImage(image, in: column)
        }
    }

    /// Up, then down, then as they come.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let i = Int(tableColumn.identifier.rawValue), columns.indices.contains(i) else { return }
        let name = columns[i]
        order =
            switch order {
            case let o? where o.column == name && o.ascending: (name, false)
            case let o? where o.column == name: nil
            default: (name, true)
            }
        indicate()
        onSort(order)
    }

    // MARK: Cells

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GridRowView() }

    /// Stripes where there are rows only: none drawn past the last.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.backgroundColor =
            row >= rows.count
            ? NSColor.systemGreen.withAlphaComponent(0.12)
            : edits.deleted.contains(row)
                ? NSColor.systemRed.withAlphaComponent(0.12)
                : row % 2 == 1 ? NSColor.alternatingContentBackgroundColors.last ?? .clear : .clear
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Asked for an old row while the columns change over to another result.
        guard let id = tableColumn?.identifier.rawValue, row < count else { return nil }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        let new = row >= rows.count, at = row - rows.count
        guard let column = Int(id) else {   // the row's number, and an agent's mark
            field.attributedStringValue = number(row, new: new)
            field.alignment = .right
            return field
        }
        let read = new ? nil : rows[row].indices.contains(column) ? rows[row][column] : nil
        let value =
            new
            ? (edits.added[at].indices.contains(column) ? edits.added[at][column] : nil)
            : edits.value(row: row, column: column) ?? read
        if let value {
            field.stringValue = value.replacingOccurrences(of: "\n", with: "⏎")
            field.font = Double(value) != nil ? .uiDigits(12) : .ui(12)
            field.alignment = Double(value) != nil ? .right : .left
            field.toolTip = value.count > 40 ? value : nil
        } else {
            field.stringValue = new ? String(localized: "default") : "NULL"
            field.font = .ui(12)
            field.textColor = .tertiaryLabelColor
        }
        if !new, edits.deleted.contains(row) {
            field.attributedStringValue = NSAttributedString(
                string: field.stringValue,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.textRed,
                    .font: field.font ?? .ui(12)
                ])
        } else if editable {
            field.isEditable = true
            field.delegate = self
            field.tag = column
        }
        if !new, edits.edited(row: row, column: column) {
            field.drawsBackground = true
            field.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25)
        }
        return field
    }

    private func number(_ row: Int, new: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if marked.contains(row) {
            text.append(
                NSAttributedString(string: "▍", attributes: [.foregroundColor: markColor, .font: NSFont.ui(11)]))
        }
        text.append(
            NSAttributedString(
                string: new ? "+" : String(row + 1),
                attributes: [.font: NSFont.uiDigits(11), .foregroundColor: NSColor.tertiaryLabelColor]))
        return text
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onChange() }

    /// An edit ends: kept, unless it's the value read (an empty field over NULL is no change).
    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField else { return }
        let row = table.row(for: field), column = field.tag
        let typed = field.stringValue
        if row >= rows.count {
            edits.setAdded(row - rows.count, column: column, to: typed.isEmpty || typed == "default" ? nil : typed)
        } else {
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
            let old = rows[row][column]
            let value: String? = old == nil && typed.isEmpty || typed == "NULL" && old == nil ? nil : typed
            edits.set(row: row, column: column, to: value, was: old)
        }
        changed(rows: [row])
    }

    func changed(rows: IndexSet? = nil) {
        if let rows {
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        } else {
            table.reloadData()
        }
        onChange()
    }

    func discard() {
        edits.clear()
        changed()
    }

    /// A new row at the end, ready to type into.
    func addRow(_ values: [String?]? = nil) {
        edits.add(values ?? Array(repeating: nil, count: columns.count))
        changed()
        table.scrollRowToVisible(count - 1)
        table.selectRowIndexes([count - 1], byExtendingSelection: false)
    }

    /// The selected rows marked to go (again: kept); new ones simply go.
    func deleteSelected() {
        for row in table.selectedRowIndexes.sorted(by: >) {
            if row >= rows.count { edits.removeAdded(row - rows.count) } else { edits.toggleDeleted(row) }
        }
        changed()
    }

    /// The selected rows as text with a header, tab between cells: for an agent.
    func text(_ rows: [Int]) -> String { ResultText.tsv(columns, rows.map { self.rows[$0] }) }
}
