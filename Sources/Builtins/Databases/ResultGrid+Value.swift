import AppKit
import DesignKit

/// A value too big for its cell: one with line breaks, or JSON. Opening such a cell (a double click), or ⌥↩ on any
/// cell, shows its value in a sheet, wrapped, JSON indented. Set (⌘↩; ↩ is a line break there) makes the text, line
/// breaks and all, the cell's edit; rows that can't be edited only show it.
extension ResultGrid {
    /// A cell's value as shown: the read value, or its edit, or what a new row holds.
    func value(row: Int, column: Int) -> String? {
        guard row < count, row >= 0 else { return nil }
        if row >= rows.count {
            let added = edits.added[row - rows.count]
            return added.indices.contains(column) ? added[column] : nil
        }
        return edits.value(row: row, column: column) ?? (rows[row].indices.contains(column) ? rows[row][column] : nil)
    }

    /// Whether opening the cell shows its value in the sheet, rather than typing over it in the cell.
    func opensInSheet(row: Int, column: Int) -> Bool {
        guard let value = value(row: row, column: column) else { return false }
        return value.contains("\n") || isJSON(column) || JSONText.pretty(value) != nil
    }

    private func isJSON(_ column: Int) -> Bool {
        columns.indices.contains(column) && info[columns[column]]?.type.lowercased().hasPrefix("json") == true
    }

    /// Opens the cell double-clicked, when its value is one for the sheet.
    @objc func openClicked() {
        let index = table.clickedColumn, row = table.clickedRow
        guard table.tableColumns.indices.contains(index),
            let column = Int(table.tableColumns[index].identifier.rawValue),
            opensInSheet(row: row, column: column)
        else { return }
        openValue(row: row, column: column)
    }

    /// ⌥↩: the cell looked at, else the first selected row's first column.
    func openSelected() {
        guard let cell = table.cellLookedAt ?? table.selectedRowIndexes.first.map({ ($0, 0) }) else {
            return NSSound.beep()
        }
        openValue(row: cell.row, column: cell.column)
    }

    func openValue(row: Int, column: Int) {
        guard columns.indices.contains(column), row >= 0, row < count else { return NSSound.beep() }
        let now = value(row: row, column: column), shown = now.map { JSONText.pretty($0) ?? $0 } ?? ""
        let name = String(localized: "\(columns[column]) of Row \(row + 1)")
        let deleted = row < rows.count && edits.deleted.contains(row)
        Task {
            guard let text = await Self.valueSheet(name, shown, editable: editable && !deleted), text != shown else {
                return
            }
            set(row: row, column: column, to: text)
            changed(rows: [row])
        }
    }

    /// Shows `text` in a sheet titled `name`. Returns the text as set, or nil when it was cancelled or only shown.
    static func valueSheet(_ name: String, _ text: String, editable: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = name
        let box = NSScrollView.readOnly(
            text, lines: max(12, text.components(separatedBy: "\n").count), width: Metrics.pageColumn)
        let view = box.documentView as? NSTextView
        view?.isEditable = editable
        view?.isRichText = false
        view?.isAutomaticQuoteSubstitutionEnabled = false
        view?.isAutomaticDashSubstitutionEnabled = false
        view?.allowsUndo = true
        alert.accessoryView = box
        alert.window.initialFirstResponder = view
        guard editable else {
            alert.addButton(withTitle: String(localized: "Close"))
            _ = await runSheet(alert)
            return nil
        }
        let set = alert.addButton(withTitle: String(localized: "Set"))
        set.keyEquivalentModifierMask = .command   // ↩ is a line break in the text
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(alert) == .alertFirstButtonReturn ? view?.string : nil
    }
}

/// JSON indented two spaces a level, its text otherwise kept as written: numbers, escapes and the keys' order stay.
enum JSONText {
    /// Returns nil for text that isn't a JSON object or array.
    static func pretty(_ text: String) -> String? {
        let json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = json.first, "{[".contains(first) else { return nil }
        let parsed = Result { try JSONSerialization.jsonObject(with: Data(json.utf8)) }
        guard case .success = parsed else { return nil }   // not JSON
        let chars = Array(json)
        var out = "", depth = 0, i = 0, quoted = false, escaped = false
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        while i < chars.count {
            let char = chars[i]
            i += 1
            if quoted {
                out.append(char)
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    quoted = false
                }
                continue
            }
            switch char {
            case "\"":
                quoted = true
                out.append(char)
            case "{", "[":
                var next = i
                while next < chars.count, chars[next].isWhitespace { next += 1 }
                if next < chars.count, chars[next] == (char == "{" ? "}" : "]") {   // empty: {} or []
                    out += String(char) + String(chars[next])
                    i = next + 1
                    continue
                }
                depth += 1
                out.append(char)
                newline()
            case "}", "]":
                depth -= 1
                newline()
                out.append(char)
            case ",":
                out.append(char)
                newline()
            case ":": out += ": "
            case _ where char.isWhitespace: continue
            default: out.append(char)
            }
        }
        return out
    }
}
