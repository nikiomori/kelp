import AppKit
import Core
import DesignKit
import EditorKit

/// A CSV file shown as a table (the tables dashboards, charts and For Each Row read): a cell changed, a row added or
/// deleted, changes the file's text, which saves as any file does; a column's head sorts the rows shown, not the file.
/// Its menu shows the text instead, and back. Text changed elsewhere (the agent, the text itself) draws it again.
@MainActor
final class CSVGrid: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let view = NSView()
    private let table = NSTableView(), scroll = NSScrollView(), editor: CodeEditor
    /// The rows, the names first; the rows' order shown; whether the text is shown instead.
    private var rows: [[String]] = [], order: [Int] = [], writing = false, text = false

    init(editor: CodeEditor) {
        self.editor = editor
        super.init()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.documentView = table
        scroll.automaticallyAdjustsContentInsets = false   // under the tab's bars, not the window's title
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        show(scroll)
        read(editor.text)
    }

    private func show(_ shown: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        shown.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shown)
        NSLayoutConstraint.activate([
            shown.topAnchor.constraint(equalTo: view.topAnchor),
            shown.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            shown.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shown.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The file's text changed: drawn again, unless the table changed it.
    func changed(_ text: String) { if !writing { read(text) } }

    private func read(_ text: String) {
        rows = DataRows.parse(text)
        let names = rows.first ?? []
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        for (i, name) in names.enumerated() {
            let column = NSTableColumn(identifier: .init(String(i)))
            column.title = name
            column.width = 140
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(i), ascending: true)
            table.addTableColumn(column)
        }
        order = Array(rows.indices.dropFirst())
        sort()
    }

    private func write() {
        writing = true
        defer { writing = false }
        editor.apply(
            text: DataRows.write(rows, separator: DataRows.separator(editor.text)),
            selection: NSRange(location: 0, length: 0))
    }

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

    func tableView(_: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard let c = column.flatMap({ Int($0.identifier.rawValue) }), order.indices.contains(row) else { return nil }
        let cells = rows[order[row]]
        return c < cells.count ? cells[c] : ""
    }

    func tableView(_: NSTableView, setObjectValue value: Any?, for column: NSTableColumn?, row: Int) {
        guard let c = column.flatMap({ Int($0.identifier.rawValue) }), order.indices.contains(row) else { return }
        let r = order[row]
        while rows[r].count <= c { rows[r].append("") }
        rows[r][c] = value as? String ?? ""
        write()
    }

    func tableView(_: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) { sort() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        menu.add(String(localized: "Add Row")) { [weak self] in
            guard let self else { return }
            rows.append(Array(repeating: "", count: rows.first?.count ?? 1))
            order.append(rows.count - 1)
            write()
            table.reloadData()
        }
        if order.indices.contains(clicked) {
            menu.add(String(localized: "Delete Row")) { [weak self] in
                guard let self else { return }
                let gone = order[clicked]
                rows.remove(at: gone)
                order = order.filter { $0 != gone }.map { $0 > gone ? $0 - 1 : $0 }
                write()
                table.reloadData()
            }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Show the Text")) { [weak self] in self?.toggle() }
    }

    /// The text instead of the table, or the table again (from the text's menu, `textItems`).
    func toggle() {
        text.toggle()
        if text {
            show(editor.view)
        } else {
            show(scroll)
            read(editor.text)
        }
    }

    /// The text's own menu gets the way back.
    func textItems(_ menu: NSMenu) {
        guard text else { return }
        menu.addItem(.separator())
        menu.add(String(localized: "Show as a Table")) { [weak self] in self?.toggle() }
    }
}
