import AppKit
import Core
import DesignKit
import KelpKit

/// The grid's table: Space shows the row, and ⌫ marks the selected rows to be deleted.
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

/// Rows as a grid. Each result column is a column, with a key's mark in its header and its type in the header's
/// tooltip when the table is known. NULL shows in grey, numbers in digits that line up, and stripes only where there
/// are rows. A table's rows can be edited, with a primary key or without one (a view's can't): cells typed over, rows
/// added at the end (green) or marked to be deleted (red), all kept in `edits` until saved. Rows that an agent's last
/// change touched carry the agent's mark in the numbers' column. A header click asks for that order (`onSort`).
@MainActor
final class ResultGrid: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let scroll = NSScrollView()
    let area = NSView()   // where the rows go in a tab: the scroll view fills it, and an empty state goes over it
    let table = GridTable()
    private(set) var columns: [String] = []
    private(set) var rows: [[String?]] = []
    /// The table's columns by name, when the rows come from a table. Their types and keys are for the header.
    private(set) var info: [String: DatabaseSchema.Column] = [:]
    /// The columns of numbers, by index. They and their headers are right-aligned.
    private var numeric: Set<Int> = []
    var edits = DatabaseEdits()
    var editable = false
    /// What a change did to these rows, when they are the rows of a run that changed something. An update's cells show
    /// what they were, a delete's rows are struck out in red, and an insert's rows are green.
    var change: RowChange?
    /// The rows (by index) that an agent's last change touched.
    var marked = Set<Int>()
    /// The order asked for: columns, each up or down, where the first counts most.
    var orders: [(column: String, ascending: Bool)] = []
    /// Called when an edit was made or undone, or the selection changed.
    var onChange: () -> Void = {}
    /// Called when a header was clicked, with `orders` set to the order to read the rows in next (empty: as they come)
    /// and the order they were in.
    var onSort: (_ was: [(column: String, ascending: Bool)]) -> Void = { _ in }
    /// Called when a foreign key's arrow is clicked, with the column and its value to follow.
    var onFollow: (_ column: String, _ value: String) -> Void = { _, _ in }
    /// The rows' height and the cells' font, as Settings › Databases sets them.
    var density = "compact" {
        didSet { table.rowHeight = TextSize.of(Self.height(density)) }
    }
    static func height(_ density: String) -> CGFloat { density == "comfortable" ? 28 : density == "normal" ? 24 : 20 }
    var font: NSFont { .uiMono(density == "comfortable" ? TextSize.body : TextSize.row) }
    /// Called for "Rows Where …" in a cell's menu, with a WHERE condition.
    var onFilter: (_ column: String, _ op: DatabaseFilters.Condition, _ value: String?) -> Void = { _, _, _ in }
    /// The table and engine the rows are of, for Copy as INSERT and the filters' quoting.
    var source: (table: String, engine: DatabaseInfo.Engine)?
    /// The most rows a table shows.
    static let shown = 1000
    /// How many rows the result had, when it had more than are shown (and so copied or exported).
    var cut: Int?

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
        area.pin(scroll)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
    }

    var selectedRows: [Int] { table.selectedRowIndexes.filter { rows.indices.contains($0) } }
    /// How many rows are shown: those read, then those added.
    var count: Int { rows.count + edits.added.count }

    /// Shows these rows. `keeping` keeps the columns' widths and which are hidden, when the columns are the same: the
    /// same table read again (another page, order or filter, or after Save).
    func show(columns: [String], rows: [[String?]], info: [DatabaseSchema.Column] = [], keeping: Bool = false) {
        let kept = keeping && columns == self.columns ? Dictionary(
            table.tableColumns.map { ($0.identifier.rawValue, (width: $0.width, hidden: $0.isHidden)) },
            uniquingKeysWith: { a, _ in a }) : [:]
        self.columns = columns
        self.rows = rows
        self.info = Dictionary(info.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        edits.clear()
        cut = nil
        marked = []
        change = nil
        numeric = Set(
            columns.indices.filter { columnIndex in
                if let type = self.info[columns[columnIndex]]?.type { return Self.isNumber(type) }
                let values = rows.prefix(200).compactMap { $0.indices.contains(columnIndex) ? $0[columnIndex] : nil }
                return !values.isEmpty && values.allSatisfy { Double($0) != nil }
            })
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        let index = NSTableColumn(identifier: .init("#"))
        // As wide as the last row's number, in the numbers' own face.
        let digit = ("0" as NSString).size(withAttributes: [.font: NSFont.uiDigits(TextSize.caption)]).width
        index.width = CGFloat(max(2, String(rows.count).count) + 2) * digit + 18   // and a mark: • − +
        index.title = ""
        table.addTableColumn(index)
        for (i, name) in columns.enumerated() {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.headerCell.attributedStringValue = header(name, right: numeric.contains(i))
            column.headerToolTip = describe(name)
            let longest = rows.prefix(60).map { ($0.indices.contains(i) ? $0[i] : nil)?.count ?? 4 }.max() ?? 0
            let fk = self.info[name]?.references == nil ? 0 : 3
            column.width = min(320, max(48, CGFloat(max(longest + fk, name.count + 2)) * charWidth + 18))
            column.minWidth = 40
            if let look = kept[String(i)] {
                column.width = look.width
                column.isHidden = look.hidden
            }
            table.addTableColumn(column)
        }
        indicate()
        table.reloadData()
        scroll.isHidden = columns.isEmpty   // no header over an empty state
    }

    /// The column's header: its name, and a key's mark for a primary key. The type, NOT NULL and what the column
    /// refers to are in its tooltip and in Structure.
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
                .chrome(TextSize.of(Metrics.iconTiny)).applying(.init(hierarchicalColor: .secondaryLabelColor)))
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

    /// A header click sorts up, then down, then as the rows come, and ⌥-click adds the column to the order kept so far.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let columnIndex = Int(tableColumn.identifier.rawValue), columns.indices.contains(columnIndex) else {
            return
        }
        let name = columns[columnIndex], adding = NSEvent.modifierFlags.contains(.option)
        let before = orders, was = orders.first { $0.column == name }
        if !adding { orders.removeAll { $0.column != name } }
        switch was {
        case let order? where order.ascending: orders = orders.map { $0.column == name ? (name, false) : $0 }
        case .some: orders.removeAll { $0.column == name }
        case nil: orders.append((name, true))
        }
        indicate()
        onSort(before)
    }

    /// Makes the column as wide as its widest value on screen, within reason.
    func sizeToFit(_ column: NSTableColumn) {
        guard let columnIndex = Int(column.identifier.rawValue), columns.indices.contains(columnIndex) else { return }
        let longest =
            rows.prefix(200).map { ($0.indices.contains(columnIndex) ? $0[columnIndex] : nil)?.count ?? 4 }.max() ?? 0
        column.width = min(600, max(48, CGFloat(max(longest, columns[columnIndex].count)) * charWidth + 24))
    }

    // MARK: Cells

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GridRowView() }

    /// Draws stripes only where there are rows, none past the last one.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? GridRowView)?.marked = marked.contains(row)
        rowView.backgroundColor =
            row >= rows.count || change?.kind == .insert
            ? NSColor.fillTint(.systemGreen)
            : edits.deleted.contains(row) || change?.kind == .delete
                ? NSColor.fillTint(.systemRed)
                : row % 2 == 1 ? NSColor.alternatingContentBackgroundColors.last ?? .clear : .clear
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // AppKit can ask for an old row while the columns change over to another result.
        guard let id = tableColumn?.identifier.rawValue, row < count else { return nil }
        let new = row >= rows.count, at = row - rows.count
        guard let column = Int(id) else {   // the row's number column (an agent's mark is the row view's)
            let field = reused(table.makeView(withIdentifier: Self.cellId, owner: nil) as? NSTextField)
            field.attributedStringValue = number(row, new: new)
            field.setAccessibilityLabel(rowName(row))
            field.alignment = .right
            return field
        }
        let read = new ? nil : rows[row].indices.contains(column) ? rows[row][column] : nil
        let value =
            new
            ? (edits.added[at].indices.contains(column) ? edits.added[at][column] : nil)
            : edits.value(row: row, column: column) ?? read
        // A foreign key gets an arrow at the cell's end that follows it to the row it names.
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

    /// The identifiers of reused cells: `makeView` hands a cell scrolled out of view back for a row scrolled into
    /// view. One is for a plain value, the other for a foreign key's value with its arrow.
    static let cellId = NSUserInterfaceItemIdentifier("grid.cell")
    static let keyCellId = NSUserInterfaceItemIdentifier("grid.key")

    /// Sets `field` up as a new cell, so nothing of the row it showed before (colour, mark, tooltip, editing) is left.
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

    /// Shows a value, NULL or DEFAULT in its field, struck through on a row marked to be deleted and orange if edited.
    private func show(_ value: String?, in field: NSTextField, row: Int, column: Int) {
        let new = row >= rows.count
        field.stringValue = Self.text(value, new: new)
        if let value {
            field.font = font
            field.alignment = numeric.contains(column) ? .right : .left
            field.toolTip = value.count > 40 ? value : nil
        } else {
            field.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            field.textColor = .tertiaryLabelColor
        }
        if !new, showChange(value, in: field, row: row, column: column) { return }
        if !new, edits.deleted.contains(row) || change?.kind == .delete {
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
            field.backgroundColor = NSColor.fillTint(.systemOrange)   // the orange of "N changes" under the grid
        }
    }

    static func aligned(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    /// Whether a type is a number type, by its first word: "integer", "double precision", "numeric(10,2)", "int
    /// unsigned", "REAL". "interval" and "point" are not.
    nonisolated static func isNumber(_ type: String) -> Bool {
        guard !type.hasSuffix("]") else { return false }   // an array of numbers ("integer[]")
        let word = type.lowercased().prefix { $0.isLetter || $0.isNumber }
        return [
            "int", "integer", "int2", "int4", "int8", "smallint", "bigint", "tinyint", "mediumint", "float", "float4",
            "float8", "double", "real", "numeric", "decimal", "number", "serial", "smallserial", "bigserial", "money"
        ].contains(String(word))
    }

    func tableViewSelectionDidChange(_ notification: Notification) { onChange() }

    func changed(rows: IndexSet? = nil) {
        if let rows {
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        } else {
            table.reloadData()
        }
        onChange()
    }

    func discard() {
        discardTyping()
        edits.clear()
        changed()
    }

    /// Adds a new row at the end, ready to type into.
    func addRow(_ values: [String?]? = nil) {
        edits.add(values ?? Array(repeating: nil, count: columns.count))
        changed()
        table.scrollRowToVisible(count - 1)
        table.selectRowIndexes([count - 1], byExtendingSelection: false)
    }

    /// Marks the selected rows to be deleted (a row marked already is kept again); new rows are simply removed.
    func deleteSelected() {
        for row in table.selectedRowIndexes.sorted(by: >) {
            if row >= rows.count { edits.removeAdded(row - rows.count) } else { edits.toggleDeleted(row) }
        }
        changed()
    }

    /// The selected rows as text for an agent, with a header and a tab between cells.
    func text(_ rows: [Int]) -> String { ResultText.tsv(columns, rows.map { self.rows[$0] }) }
}
