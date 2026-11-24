import AppKit
import Core
import DesignKit
import KelpKit

/// Rows as text to copy or save: TSV (what a spreadsheet pastes), CSV, JSON (an object per row), a Markdown table, or
/// INSERT statements for the table they came from.
enum ResultText {
    enum Format: String, CaseIterable {
        case tsv = "TSV", csv = "CSV", json = "JSON", markdown = "Markdown", insert = "INSERT"

        var fileExtension: String {
            switch self {
            case .tsv: "tsv"
            case .csv: "csv"
            case .json: "json"
            case .markdown: "md"
            case .insert: "sql"
            }
        }
    }

    /// `types` are the columns' types where known (a table's), for which are numbers in JSON; `from` is the table the
    /// rows came from, for INSERT.
    static func text(
        _ format: Format, _ columns: [String], _ rows: [[String?]], types: [String?],
        from: (table: String?, engine: DatabaseInfo.Engine?)
    ) -> String {
        switch format {
        case .tsv: tsv(columns, rows)
        case .csv: csv(columns, rows)
        case .json: json(columns, rows, types: types)
        case .markdown: markdown(columns, rows)
        case .insert: insert(columns, rows, table: from.table ?? "t", engine: from.engine ?? .postgres)
        }
    }

    static func tsv(_ columns: [String], _ rows: [[String?]]) -> String {
        ([columns.joined(separator: "\t")] + rows.map { $0.map { $0 ?? "NULL" }.joined(separator: "\t") })
            .joined(separator: "\n")
    }

    static func csv(_ columns: [String], _ rows: [[String?]]) -> String {
        func field(_ value: String?) -> String {
            guard let value else { return "" }
            return value.contains(where: { ",\"\n\r".contains($0) })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        return ([columns.map(field).joined(separator: ",")] + rows.map { $0.map(field).joined(separator: ",") })
            .joined(separator: "\n") + "\n"
    }

    /// Rows as JSON, where a number column's numbers stay numbers (exactly, however long), JSON stays JSON and NULL is
    /// null; the rest are strings. A column's type says which are numbers: without one (a query's rows), a column is of
    /// numbers when every value is written as JSON writes one, so a zip code with its leading zero stays text.
    static func json(_ columns: [String], _ rows: [[String?]], types: [String?] = []) -> String {
        let numbers = Set(
            columns.indices.filter { i in
                if types.indices.contains(i), let type = types[i] { return ResultGrid.isNumber(type) }
                let values = rows.compactMap { $0.indices.contains(i) ? $0[i] : nil }
                return !values.isEmpty && values.allSatisfy { $0.wholeMatch(of: jsonNumber) != nil }
            })
        let objects = rows.map { row -> [String: Any] in
            var object: [String: Any] = [:]
            for (i, name) in columns.enumerated() where row.indices.contains(i) {
                guard let value = row[i] else {
                    object[name] = NSNull()
                    continue
                }
                if numbers.contains(i), let number = exactNumber(value) {
                    object[name] = number
                } else if value.first == "{" || value.first == "[", let parsed = parsedJSON(value) {
                    object[name] = parsed
                } else {
                    object[name] = value
                }
            }
            return object
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        } catch { return "[]" }   // only strings, finite numbers and parsed JSON go in, so it can't fail
    }

    /// A number as JSON writes it: no leading zero, no NaN or Infinity.
    private static var jsonNumber: Regex<Substring> { /-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/ }

    /// The number a cell's text is, written with every digit it has, or nil for one JSON has no number for (NaN,
    /// Infinity, 1e999) or that has more digits than a decimal keeps: those stay text.
    private static func exactNumber(_ value: String) -> NSDecimalNumber? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.wholeMatch(of: jsonNumber) != nil,
            trimmed.prefix { $0 != "e" && $0 != "E" }.filter(\.isNumber).drop { $0 == "0" }.count <= 38,
            let decimal = Decimal(string: trimmed), decimal.isFinite
        else { return nil }
        return NSDecimalNumber(decimal: decimal)
    }

    /// The JSON a cell holds, or nil for text that only starts like JSON.
    private static func parsedJSON(_ value: String) -> Any? {
        do { return try JSONSerialization.jsonObject(with: Data(value.utf8)) } catch { return nil }
    }

    static func markdown(_ columns: [String], _ rows: [[String?]]) -> String {
        func cell(_ s: String?) -> String {
            (s ?? "NULL").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        let head = "| " + columns.map(cell).joined(separator: " | ") + " |"
        let rule = "|" + columns.map { _ in " --- |" }.joined()
        return ([head, rule] + rows.map { "| " + $0.map(cell).joined(separator: " | ") + " |" }).joined(separator: "\n")
    }

    static func insert(_ columns: [String], _ rows: [[String?]], table: String, engine: DatabaseInfo.Engine) -> String {
        let names = columns.map { DatabaseEdits.name($0, engine) }.joined(separator: ", ")
        return rows.map { row in
            "INSERT INTO \(DatabaseEdits.name(table, engine)) (\(names)) VALUES ("
                + row.map { engine.literal($0) }.joined(separator: ", ") + ");"
        }.joined(separator: "\n")
    }
}

extension ResultGrid: NSMenuDelegate {
    /// The columns' types, nil where the rows don't come from a table.
    var types: [String?] { columns.map { info[$0]?.type } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let header = table.headerView, menu === header.menu { return headerMenu(menu, header) }
        let row = table.clickedRow, column = table.clickedColumn - 1   // the first column is the rows' numbers
        guard row >= 0, row < count else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let picked = selectedRows, read = row < rows.count
        if read, rows[row].indices.contains(column), source != nil {
            let value = rows[row][column], name = columns[column]
            let shown = value.map { $0.count > 24 ? String($0.prefix(23)) + "…" : $0 }
            if let shown {
                menu.add(String(localized: "Rows Where \(name) = \(shown)")) { [weak self] in
                    self?.onFilter(name, .equal, value)
                }
                menu.add(String(localized: "Rows Where \(name) ≠ \(shown)")) { [weak self] in
                    self?.onFilter(name, .notEqual, value)
                }
            } else {
                menu.add(String(localized: "Rows Where \(name) Is NULL")) { [weak self] in
                    self?.onFilter(name, .isNull, nil)
                }
            }
            menu.addItem(.separator())
        }
        if read, rows[row].indices.contains(column) {
            let value = rows[row][column]
            menu.add(String(localized: "Copy Value")) { copyText(value ?? "NULL") }
        }
        let copyAs = NSMenu()
        for format in ResultText.Format.allCases {
            copyAs.add(format.rawValue) { [weak self] in
                guard let self else { return }
                copyText(
                    ResultText.text(
                        format, columns, picked.map { self.rows[$0] }, types: types,
                        from: (source?.table, source?.engine)))
            }
        }
        menu.add(String(localized: "Copy Rows As"), submenu: copyAs)
        guard editable else { return }
        menu.addItem(.separator())
        if read, rows[row].indices.contains(column), rows[row][column] != nil || edits.edited(row: row, column: column)
        {
            let value = rows[row][column]
            menu.add(String(localized: "Set to NULL")) { [weak self] in
                guard let self else { return }
                edits.set(row: row, column: column, to: nil, was: value)
                changed(rows: [row])
            }
        }
        if read {
            menu.add(String(localized: "Duplicate Row")) { [weak self] in
                guard let self else { return }
                // The key is left out, so the database gives the copy its own.
                let copy = rows[row].enumerated().map { i, v in info[columns[i]]?.primary == true ? nil : v }
                addRow(copy)
            }
        }
        menu.add(
            picked.count > 1 ? String(localized: "Delete \(picked.count) Rows") : String(localized: "Delete Row")
        ) { [weak self] in self?.deleteSelected() }
    }
}

extension ResultGrid {
    /// The menu on a column's header: its order, hiding it (and bringing all columns back), and its width.
    func headerMenu(_ menu: NSMenu, _ header: NSTableHeaderView) {
        let at = header.convert(header.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let index = header.column(at: at)
        guard table.tableColumns.indices.contains(index),
            let columnIndex = Int(table.tableColumns[index].identifier.rawValue),
            columns.indices.contains(columnIndex)
        else { return }
        let column = table.tableColumns[index], name = columns[columnIndex]
        for (title, up) in [(String(localized: "Sort Ascending"), true), (String(localized: "Sort Descending"), false)]
        {
            menu.add(title) { [weak self] in self?.sort([(name, up)]) }
        }
        if !orders.isEmpty {
            menu.add(String(localized: "Don’t Sort")) { [weak self] in self?.sort([]) }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Hide \(name)")) { column.isHidden = true }
        if table.tableColumns.contains(where: \.isHidden) {
            menu.add(String(localized: "Show All Columns")) { [weak self] in
                self?.table.tableColumns.forEach { $0.isHidden = false }
            }
        }
        menu.add(String(localized: "Size to Fit")) { [weak self] in self?.sizeToFit(column) }
        menu.add(String(localized: "Size All Columns to Fit")) { [weak self] in
            self?.table.tableColumns.dropFirst().forEach { self?.sizeToFit($0) }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Name")) { copyText(name) }
    }

    private func sort(_ order: [(column: String, ascending: Bool)]) {
        let was = orders
        orders = order
        indicate()
        onSort(was)
    }
}
