import AppKit
import Core
import KelpKit

/// Rows as text to copy or save: TSV (what a spreadsheet pastes), CSV, JSON (an object a row), a Markdown table, or
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

    static func text(
        _ format: Format, _ columns: [String], _ rows: [[String?]], table: String?, engine: DatabaseInfo.Engine?
    ) -> String {
        switch format {
        case .tsv: tsv(columns, rows)
        case .csv: csv(columns, rows)
        case .json: json(columns, rows)
        case .markdown: markdown(columns, rows)
        case .insert: insert(columns, rows, table: table ?? "t", engine: engine ?? .postgres)
        }
    }

    static func tsv(_ columns: [String], _ rows: [[String?]]) -> String {
        ([columns.joined(separator: "\t")] + rows.map { $0.map { $0 ?? "NULL" }.joined(separator: "\t") })
            .joined(separator: "\n")
    }

    static func csv(_ columns: [String], _ rows: [[String?]]) -> String {
        func field(_ s: String?) -> String {
            guard let s else { return "" }
            return s.contains(where: { ",\"\n\r".contains($0) })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([columns.map(field).joined(separator: ",")] + rows.map { $0.map(field).joined(separator: ",") })
            .joined(separator: "\n") + "\n"
    }

    /// Numbers stay numbers, JSON stays JSON, NULL is null; the rest are strings.
    static func json(_ columns: [String], _ rows: [[String?]]) -> String {
        let objects = rows.map { row -> [String: Any] in
            var object: [String: Any] = [:]
            for (i, name) in columns.enumerated() where row.indices.contains(i) {
                guard let value = row[i] else {
                    object[name] = NSNull()
                    continue
                }
                if let number = Double(value), value.first != "0" || value == "0" || value.hasPrefix("0.") {
                    object[name] = number == number.rounded() && abs(number) < 1e15 ? Int64(number) as Any : number
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
        } catch { return "[]" }   // only strings, numbers and what was parsed go in: it can't fail
    }

    /// A cell that holds JSON, as JSON; nil for text that only starts like it.
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
                + row.map { DatabaseEdits.literal($0, engine) }.joined(separator: ", ") + ");"
        }.joined(separator: "\n")
    }

    /// A WHERE condition for a cell's value: "status = 'pending'", "note IS NULL".
    static func condition(_ column: String, _ value: String?, equal: Bool, engine: DatabaseInfo.Engine) -> String {
        let name = DatabaseEdits.name(column, engine)
        guard let value else { return name + (equal ? " IS NULL" : " IS NOT NULL") }
        return name + (equal ? " = " : " <> ") + DatabaseEdits.literal(value, engine)
    }
}

extension ResultGrid: NSMenuDelegate {
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
                        format, columns, picked.map { self.rows[$0] }, table: source?.table, engine: source?.engine))
            }
        }
        menu.setSubmenu(
            copyAs, for: menu.addItem(withTitle: String(localized: "Copy Rows As"), action: nil, keyEquivalent: ""))
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
                // its key left out: the database gives the copy its own
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
    /// A column's header: its order, hiding it (and bringing all back), its width.
    func headerMenu(_ menu: NSMenu, _ header: NSTableHeaderView) {
        let at = header.convert(header.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let index = header.column(at: at)
        guard table.tableColumns.indices.contains(index), let i = Int(table.tableColumns[index].identifier.rawValue),
            columns.indices.contains(i)
        else { return }
        let column = table.tableColumns[index], name = columns[i]
        for (title, up) in [(String(localized: "Sort Ascending"), true), (String(localized: "Sort Descending"), false)]
        {
            menu.add(title) { [weak self] in
                self?.orders = [(name, up)]
                self?.indicate()
                self?.onSort()
            }
        }
        if !orders.isEmpty {
            menu.add(String(localized: "Don’t Sort")) { [weak self] in
                self?.orders = []
                self?.indicate()
                self?.onSort()
            }
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
}
