import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// A query of the user's own, in Kelp's editor: SQL colours, the database's tables and columns offered as words are
/// typed, ⌘↩ runs the statement the cursor is in (one at a time, as an agent's), Explain shows the plan.
extension DatabaseTab {
    func buildEditor() {
        editor.view.heightAnchor.constraint(equalToConstant: 160).isActive = true
        editor.completionProvider = { [weak self] line, column in
            await MainActor.run { self?.completions(line: line, column: column) ?? [] }
        }
    }

    /// Tables, then the columns of the tables the statement names, then SQL's own words: what starts with the word
    /// being typed.
    func completions(line: Int, column: Int) -> [CodeEditor.Completion] {
        let text = editor.textView.string
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1) else { return [] }
        let before = String(lines[line - 1].prefix(max(0, column - 1)))
        let word = String(before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed()).lowercased()
        let named = tables.filter { text.lowercased().contains($0.name.lowercased()) }
        let tableWords = tables.map {
            CodeEditor.Completion(label: $0.name, detail: $0.rows.map { "\($0) rows" }, insert: $0.name, kind: "class")
        }
        let columnWords = named.flatMap { t in
            t.columns.map {
                CodeEditor.Completion(label: $0.name, detail: $0.type.lowercased(), insert: $0.name, kind: "field")
            }
        }
        let keywords = Self.keywords.map { CodeEditor.Completion(label: $0, insert: $0, kind: "keyword") }
        return (columnWords + tableWords + keywords).filter { word.isEmpty || $0.label.lowercased().hasPrefix(word) }
    }

    static let keywords = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "ILIKE", "BETWEEN", "ORDER BY",
        "GROUP BY", "HAVING", "LIMIT", "OFFSET", "JOIN", "LEFT JOIN", "INNER JOIN", "ON", "AS", "DISTINCT", "COUNT",
        "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH", "CASE", "WHEN", "THEN", "ELSE",
        "END"
    ]

    func startedQuery() {
        arrange()
        heading.stringValue = String(localized: "Query")
        if editor.textView.string.isEmpty, let first = tables.first {
            editor.textView.string = "SELECT * FROM " + DatabaseEdits.name(first.name, engine) + " LIMIT 100;"
        }
        grid.editable = false
        grid.source = nil
        grid.show(columns: [], rows: [])
        empty.show(
            String(localized: "Run a Statement"), symbol: "play",
            text: String(localized: "⌘↩ runs the statement the cursor is in. Words from the tables come as you type."))
        status.stringValue = ""
        view.window?.makeFirstResponder(editor.textView)
    }

    /// The statement the cursor is in: between the semicolons around it, quotes respected.
    func statementAtCursor() -> String {
        let text = editor.textView.string as NSString
        let at = editor.textView.selectedRange()
        if at.length > 0 { return text.substring(with: at) }
        var start = 0, quote: unichar?
        var bounds: [(Int, Int)] = []
        for i in 0..<text.length {
            let c = text.character(at: i)
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 39 || c == 34 {   // ' "
                quote = c
            } else if c == 59 {   // ;
                bounds.append((start, i))
                start = i + 1
            }
        }
        bounds.append((start, text.length))
        let cursor = at.location
        let (s, e) =
            bounds.first {
                cursor >= $0.0 && cursor <= $0.1
                    && !text.substring(with: NSRange(location: $0.0, length: $0.1 - $0.0)).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            }
            ?? bounds.last {
                !text.substring(with: NSRange(location: $0.0, length: $0.1 - $0.0)).trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
            ?? (0, text.length)
        return text.substring(with: NSRange(location: s, length: e - s)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc func runQuery() { execute(statementAtCursor()) }

    /// The plan, as the engine says it.
    @objc func explainQuery() {
        let sql = statementAtCursor()
        execute((engine == .sqlite ? "EXPLAIN QUERY PLAN " : "EXPLAIN ") + sql)
    }

    private func execute(_ sql: String) {
        guard !sql.isEmpty else { return NSSound.beep() }
        Task {
            guard let result = await query(sql) else { return }
            grid.show(columns: result.columns, rows: result.rows)
            empty.show(
                result.columns.isEmpty
                    ? String(localized: "Done") : result.rows.isEmpty ? String(localized: "No Rows") : nil)
            status.stringValue =
                (result.changed.map { String(localized: "\($0) rows changed") }
                    ?? String(localized: "\(result.total) rows")) + " · \(result.ms) ms"
            await loadTables()   // a CREATE or a DROP changes the list
        }
    }
}
