import AppKit

/// Typing in the grid's cells. A cell shows a line break as ⏎, and NULL or, in a new row, DEFAULT in grey; the field
/// editor gets that text too, so a cell entered and left as it showed keeps its value.
extension ResultGrid {
    /// What a cell shows of a value.
    static func text(_ value: String?, new: Bool) -> String {
        value.map { $0.replacingOccurrences(of: "\n", with: "⏎") } ?? (new ? String(localized: "DEFAULT") : "NULL")
    }

    /// What `typed` in a cell makes its value (`.some(nil)`: NULL, or the default in a new row), or nil when it
    /// changes nothing: the cell's own text left as it showed, or an empty field over NULL.
    func change(_ typed: String, row: Int, column: Int) -> String?? {
        let new = row >= rows.count, at = row - rows.count
        let now: String?
        if new {
            guard edits.added.indices.contains(at), edits.added[at].indices.contains(column) else { return nil }
            now = edits.added[at][column]
        } else {
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
            now = edits.value(row: row, column: column) ?? rows[row][column]
        }
        guard typed != Self.text(now, new: new), !(typed.isEmpty && now == nil) else { return nil }
        if new, typed.isEmpty || typed.caseInsensitiveCompare(Self.text(nil, new: true)) == .orderedSame {
            return .some(nil)
        }
        // A value with line breaks showed them as ⏎, so the ⏎ left in it are its line breaks.
        return .some(now?.contains("\n") == true ? typed.replacingOccurrences(of: "⏎", with: "\n") : typed)
    }

    /// When an edit ends, it is kept unless it leaves the cell as it was.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = table.row(for: field), column = field.tag
        guard row >= 0 else { return }
        if let value = change(field.stringValue, row: row, column: column) { set(row: row, column: column, to: value) }
        changed(rows: [row])
    }

    /// The cell being typed in, and what is typed so far.
    private var typingCell: (field: NSTextField, text: String)? {
        guard let editor = table.window?.firstResponder as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSTextField, field.isDescendant(of: table)
        else { return nil }
        return (field, editor.string)
    }

    /// Whether a cell is being typed in and what is typed would change it, so the tab counts as edited.
    var typing: Bool {
        guard let cell = typingCell else { return false }
        return change(cell.text, row: table.row(for: cell.field), column: cell.field.tag) != nil
    }

    /// Ends the typing in a cell, so what is typed is an edit (before Save, or a question about the edits).
    func commitTyping() {
        guard typingCell != nil else { return }
        table.window?.makeFirstResponder(table)
    }

    /// Set to NULL from the keys: the cell being typed in becomes NULL (in a new row, its default).
    func setTypingToNull() {
        guard let cell = typingCell else { return NSSound.beep() }
        let row = table.row(for: cell.field), column = cell.field.tag
        cell.field.abortEditing()
        if rows.indices.contains(row) || row >= rows.count { set(row: row, column: column, to: nil) }
        changed(rows: [row])
    }

    /// Adds a copy of each selected row read, at the end. The key is left out, so the database gives each its own.
    func duplicateSelected() {
        let picked = selectedRows
        guard !picked.isEmpty else { return NSSound.beep() }
        for row in picked {
            addRow(rows[row].enumerated().map { i, v in info[columns[i]]?.primary == true ? nil : v })
        }
    }

    /// Drops what is typed in a cell, with the edits.
    func discardTyping() { typingCell?.field.abortEditing() }
}
