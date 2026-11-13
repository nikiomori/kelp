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
    /// Columns of numbers (by index): they, and their headers, stand right.
    private var numeric: Set<Int> = []
    var edits = DatabaseEdits()
    var editable = false
    /// Rows an agent's last change touched (by index), and that agent's colour.
    var marked = Set<Int>()
    var markColor = NSColor.systemOrange
    /// The order asked for: a column and whether it goes up.
    /// The order asked for: columns, each up or down; the first counts most.
    var orders: [(column: String, ascending: Bool)] = []
    /// An edit was made or undone, or the selection changed.
    var onChange: () -> Void = {}
    /// A header was clicked: the order to read the rows in next (nil: as they come).
    var onSort: () -> Void = {}
    /// A foreign key's arrow: that column's value, to follow.
    var onFollow: (_ column: String, _ value: String) -> Void = { _, _ in }
    /// Rows' height and the cells' font, as Settings › Databases says.
    var density = "compact" {
        didSet { table.rowHeight = TextSize.of(Self.height(density)) }
    }
    static func height(_ density: String) -> CGFloat { density == "comfortable" ? 28 : density == "normal" ? 24 : 20 }
    private var font: NSFont { .uiMono(density == "comfortable" ? 12.5 : 11.5) }
    /// "Rows Where …" from a cell's menu: a WHERE condition.
    var onFilter: (_ column: String, _ op: DatabaseFilters.Condition, _ value: String?) -> Void = { _, _, _ in }
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
        table.rowHeight = TextSize.of(Self.height(density))
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.headerView?.menu = NSMenu()
        table.headerView?.menu?.delegate = self
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
        numeric = Set(
            columns.indices.filter { columnIndex in
                if let type = self.info[columns[columnIndex]]?.type { return Self.isNumber(type) }
                let values = rows.prefix(200).compactMap { $0.indices.contains(columnIndex) ? $0[columnIndex] : nil }
                return !values.isEmpty && values.allSatisfy { Double($0) != nil }
            })
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        let index = NSTableColumn(identifier: .init("#"))
        index.width = 44
        index.title = ""
        table.addTableColumn(index)
        for (i, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.headerCell.attributedStringValue = header(name, right: numeric.contains(i))
            column.headerToolTip = describe(name)
            let longest = rows.prefix(60).map { ($0.indices.contains(i) ? $0[i] : nil)?.count ?? 4 }.max() ?? 0
            let fk = self.info[name]?.references == nil ? 0 : 3
            column.width = min(320, max(48, CGFloat(max(longest + fk, name.count + 2)) * 7.2 + 18))
            column.minWidth = 40
            table.addTableColumn(column)
        }
        indicate()
        table.reloadData()
    }

    /// "id int8 ⚿", "user_id int8 → users": the name, then its type and keys quieter.
    /// The name only, and a key's mark: the type, NOT NULL and what it refers to are in its tooltip and Structure.
    private func header(_ name: String, right: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.ui(TextSize.caption, weight: .semibold), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: Self.aligned(right ? .right : .left)
            ])
        if info[name]?.primary == true {
            let mark = NSTextAttachment()
            mark.image = NSImage.symbol("key.fill", String(localized: "primary key")).withSymbolConfiguration(
                .init(pointSize: 8, weight: .regular).applying(.init(hierarchicalColor: .systemOrange)))
            text.append(NSAttributedString(string: " "))
            text.append(NSAttributedString(attachment: mark))
        }
        return text
    }

    private func describe(_ name: String) -> String {
        guard let column = info[name] else { return name }
        return [
            "\(name): \(column.type)", column.nullable ? nil : "NOT NULL",
            column.primary ? String(localized: "primary key") : nil,
            column.references.map { String(localized: "refers to \($0)") }
        ].compactMap { $0 }.joined(separator: " · ")
    }

    func indicate() {
        for column in table.tableColumns {
            let name = Int(column.identifier.rawValue).flatMap { columns.indices.contains($0) ? columns[$0] : nil }
            let image = orders.first { $0.column == name }.flatMap { order in
                NSImage(named: order.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
            }
            table.setIndicatorImage(image, in: column)
        }
    }

    /// Up, then down, then as they come; ⌥-click adds a column to the order instead of starting over.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let columnIndex = Int(tableColumn.identifier.rawValue), columns.indices.contains(columnIndex) else {
            return
        }
        let name = columns[columnIndex], adding = NSEvent.modifierFlags.contains(.option)
        let was = orders.first { $0.column == name }
        if !adding { orders.removeAll { $0.column != name } }
        switch was {
        case let order? where order.ascending: orders = orders.map { $0.column == name ? (name, false) : $0 }
        case .some: orders.removeAll { $0.column == name }
        case nil: orders.append((name, true))
        }
        indicate()
        onSort()
    }

    /// As wide as its widest value on screen, within reason.
    func sizeToFit(_ column: NSTableColumn) {
        guard let columnIndex = Int(column.identifier.rawValue), columns.indices.contains(columnIndex) else { return }
        let longest =
            rows.prefix(200).map { ($0.indices.contains(columnIndex) ? $0[columnIndex] : nil)?.count ?? 4 }.max() ?? 0
        column.width = min(600, max(48, CGFloat(max(longest, columns[columnIndex].count)) * 7.2 + 24))
    }

    // MARK: Cells

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GridRowView() }

    /// Stripes where there are rows only: none drawn past the last.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.backgroundColor =
            row >= rows.count
            ? NSColor.fillTint(.systemGreen)
            : edits.deleted.contains(row)
                ? NSColor.fillTint(.systemRed)
                : row % 2 == 1 ? NSColor.alternatingContentBackgroundColors.last ?? .clear : .clear
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Asked for an old row while the columns change over to another result.
        guard let id = tableColumn?.identifier.rawValue, row < count else { return nil }
        let new = row >= rows.count, at = row - rows.count
        guard let column = Int(id) else {   // the row's number, and an agent's mark
            let field = reused(table.makeView(withIdentifier: Self.cellId, owner: nil) as? NSTextField)
            field.attributedStringValue = number(row, new: new)
            field.alignment = .right
            return field
        }
        let read = new ? nil : rows[row].indices.contains(column) ? rows[row][column] : nil
        let value =
            new
            ? (edits.added[at].indices.contains(column) ? edits.added[at][column] : nil)
            : edits.value(row: row, column: column) ?? read
        // A foreign key: an arrow at the cell's end follows it to the row it names.
        let name = columns.indices.contains(column) ? columns[column] : ""
        guard let value, info[name]?.references != nil, !new else {
            let field = reused(table.makeView(withIdentifier: Self.cellId, owner: nil) as? NSTextField)
            show(value, in: field, row: row, column: column)
            return field
        }
        let cell = table.makeView(withIdentifier: Self.keyCellId, owner: nil) as? NSStackView ?? keyCell()
        guard let field = cell.arrangedSubviews.first as? NSTextField,
            let follow = cell.arrangedSubviews.last as? IconButton
        else { return cell }
        show(value, in: reused(field), row: row, column: column)
        follow.onClick = { [weak self] in self?.onFollow(name, value) }
        return cell
    }

    /// Scrolled-away cells come back for the rows scrolled to (`makeView`): a plain value's, and a foreign key's with
    /// its arrow.
    static let cellId = NSUserInterfaceItemIdentifier("grid.cell")
    static let keyCellId = NSUserInterfaceItemIdentifier("grid.key")

    /// `field` as a new cell's, whatever row it showed before: no colour, mark, tooltip or editing of that row's left.
    private func reused(_ field: NSTextField?) -> NSTextField {
        guard let field else {
            let made = NSTextField(labelWithString: "")
            made.identifier = Self.cellId
            made.lineBreakMode = .byTruncatingTail
            made.cell?.usesSingleLineMode = true
            return made
        }
        field.attributedStringValue = NSAttributedString()
        field.textColor = .labelColor
        field.alignment = .natural
        field.toolTip = nil
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        field.tag = 0
        return field
    }

    private func keyCell() -> NSStackView {
        let field = reused(nil)
        field.identifier = nil
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let follow = IconButton(.symbol("arrow.forward"), tip: String(localized: "Open the Row It Refers To")) {}
        follow.symbolConfiguration = .chrome(Metrics.iconTiny)
        let cell = NSStackView(views: [field, follow])
        cell.identifier = Self.keyCellId
        cell.spacing = 2
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
        return cell
    }

    /// A value, NULL or DEFAULT in its field: struck through on a row marked to go, yellow where it was edited.
    private func show(_ value: String?, in field: NSTextField, row: Int, column: Int) {
        let new = row >= rows.count
        if let value {
            field.stringValue = value.replacingOccurrences(of: "\n", with: "⏎")
            field.font = font
            field.alignment = numeric.contains(column) ? .right : .left
            field.toolTip = value.count > 40 ? value : nil
        } else {
            field.stringValue = new ? String(localized: "DEFAULT") : "NULL"
            field.font = NSFontManager.shared.convert(.uiMono(10.5), toHaveTrait: .italicFontMask)
            field.textColor = .tertiaryLabelColor
        }
        if !new, edits.deleted.contains(row) {
            field.attributedStringValue = NSAttributedString(
                string: field.stringValue,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.textRed,
                    .font: field.font ?? .ui(TextSize.row), .paragraphStyle: Self.aligned(field.alignment)
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
    }

    private func number(_ row: Int, new: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if marked.contains(row) {
            text.append(
                NSAttributedString(
                    string: "▍", attributes: [.foregroundColor: markColor, .font: NSFont.ui(TextSize.caption)]))
        }
        text.append(
            NSAttributedString(
                string: new ? "+" : String(row + 1),
                attributes: [.font: NSFont.uiDigits(TextSize.caption), .foregroundColor: NSColor.tertiaryLabelColor]))
        // An attributed string keeps its own alignment: the field's `.right` doesn't reach it.
        text.addAttribute(
            .paragraphStyle, value: Self.aligned(.right), range: NSRange(location: 0, length: text.length))
        return text
    }

    private static func aligned(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    /// "integer", "double precision", "numeric(10,2)", "int unsigned", "REAL": a number type, by its first word.
    /// Not "interval" or "point".
    nonisolated static func isNumber(_ type: String) -> Bool {
        let word = type.lowercased().prefix { $0.isLetter || $0.isNumber }
        return [
            "int", "integer", "int2", "int4", "int8", "smallint", "bigint", "tinyint", "mediumint", "float", "float4",
            "float8", "double", "real", "numeric", "decimal", "number", "serial", "smallserial", "bigserial", "money"
        ].contains(String(word))
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
