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
        let columnWords = named.flatMap { table in
            table.columns.map {
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
            let char = text.character(at: i)
            if let opening = quote {
                if char == opening { quote = nil }
            } else if char == 39 || char == 34 {   // ' "
                quote = char
            } else if char == 59 {   // ;
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

    // MARK: Saved queries (state.get/set: "db.queries/<project>/<database>")

    private var queriesKey: String {
        let library = app.latest(DatabasesEvent.self, address.worktree)?.library?.contains { $0.name == address.name }
        let project = library == true ? "~" : app.worktree(address.worktree)?.repoId ?? address.worktree
        return "db.queries/\(project)/\(address.name)"
    }

    func loadQueries() async {
        guard let value = await app.quiet(StateGet(key: queriesKey)), case .array(let items) = value else { return }
        sidebar.saved = items.compactMap { item in
            guard case .object(let fields) = item, case .string(let name)? = fields["name"],
                case .string(let sql)? = fields["sql"]
            else { return nil }
            return DatabaseSidebar.SavedQuery(name: name, sql: sql)
        }
    }

    private func storeQueries(_ list: [DatabaseSidebar.SavedQuery]) {
        sidebar.saved = list
        let value = JSONValue.array(list.map { .object(["name": .string($0.name), "sql": .string($0.sql)]) })
        Task { _ = await app.call(StateSet(key: queriesKey, value: value)) }
    }

    /// Save Query…: the statement under a name, in the list's Queries.
    @objc func keepQuery() {
        let sql = editor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the query as")
        let name = NSTextField(string: sql.split(whereSeparator: \.isNewline).first.map { String($0.prefix(40)) } ?? "")
        name.frame = NSRect(x: 0, y: 0, width: Metrics.alertAccessory, height: 22)
        alert.accessoryView = name
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Task {
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            storeQueries(
                sidebar.saved.filter { $0.name != title } + [.init(name: title.isEmpty ? sql : title, sql: sql)])
        }
    }

    func openSaved(_ q: DatabaseSidebar.SavedQuery) {
        editor.textView.string = q.sql
        Task { await leave(to: .query) }
    }

    func forget(_ q: DatabaseSidebar.SavedQuery) { storeQueries(sidebar.saved.filter { $0 != q }) }

    /// The plan, as the engine says it.
    @objc func explainQuery() {
        let sql = statementAtCursor()
        execute(engine.explain + sql)
    }

    private func execute(_ sql: String) {
        guard !sql.isEmpty else { return NSSound.beep() }
        startReading()
        Task {
            let result = await query(sql)
            reading?.cancel()
            busy.stopAnimation(nil)
            guard let result else { return }
            grid.show(columns: result.columns, rows: result.rows)
            empty.show(
                result.columns.isEmpty
                    ? String(localized: "Done") : result.rows.isEmpty ? String(localized: "No Rows") : nil)
            status.stringValue =
                (result.changed.map { String(localized: "\($0) rows changed") }
                    ?? String(localized: "\(result.total) rows")) + " · " + Self.took(result.ms)
            await loadTables()   // a CREATE or a DROP changes the list
        }
    }
}
