import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// A query of the user's own, in Kelp's editor. It has SQL colours and offers the database's tables and columns as
/// words are typed. ⌘↩ runs the statement the cursor is in (one at a time, as an agent's statements run), and Explain
/// shows the plan. What is typed is kept for the database (`db.draft/…`), so it is still there when the tab opens
/// again.
extension DatabaseTab {
    /// Builds the editor above the rows, with a divider between them for the user to drag. The editor stays as tall
    /// as the user left it, kept per Mac like the tab's other split.
    func buildEditor() -> NSView {
        editor.completionProvider = { [weak self] line, column in
            await MainActor.run { self?.completions(line: line, column: column) ?? [] }
        }
        editor.onChange = { [weak self] _ in self?.draft.after(0.5) { self?.keepDraft() } }
        let rows = NSSplitView()
        rows.isVertical = false
        rows.dividerStyle = .thin
        for pane in [editor.view, grid.area] { rows.addArrangedSubview(pane) }
        rows.setHoldingPriority(.init(260), forSubviewAt: 0)
        rows.setHoldingPriority(.init(200), forSubviewAt: 1)
        editor.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        grid.area.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        // The split starts from its panes' frames, as the tab's own split does, so the editor is 160 tall until it's
        // dragged.
        editor.view.setFrameSize(NSSize(width: 800, height: 160))
        grid.area.setFrameSize(NSSize(width: 800, height: 400))
        rows.autosaveName = "DatabaseQuery"
        return rows
    }

    /// The completions for the word being typed: tables, then the columns of the tables the statement names, then
    /// SQL's own words, each starting with that word.
    func completions(line: Int, column: Int) -> [CodeEditor.Completion] {
        let text = editor.text
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
        // A new query starts from the table just looked at, and the list selects nothing while a query is shown.
        let from = sidebar.current ?? tables.first?.name
        sidebar.current = nil
        arrange()
        if editor.text.isEmpty, let from {
            editor.setText("SELECT * FROM " + DatabaseEdits.name(from, engine) + " LIMIT 100;")
        }
        grid.editable = false
        grid.source = nil
        grid.show(columns: [], rows: [])
        empty.show(
            String(localized: "Run a Statement"), symbol: "play.fill",
            text: String(localized: "⌘↩ runs the statement the cursor is in. Words from the tables come as you type."))
        status.stringValue = ""
        editor.focus()
    }

    /// The statement the cursor is in, between the semicolons around it, with quotes respected.
    func statementAtCursor() -> String {
        let text = editor.text as NSString
        let at = editor.selectedRange
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

    // MARK: Saved queries (Kelp's state, `app.uiState`: "db.queries/<project>/<database>")

    private var queriesKey: String { key("queries") }

    /// The key under which Kelp's state keeps the saved queries and the draft: "db.<what>/<project>/<database>".
    private func key(_ what: String) -> String {
        let library = app.latest(DatabasesEvent.self, address.worktree)?.library?.contains { $0.name == address.name }
        let project = library == true ? "~" : app.worktree(address.worktree)?.repoId ?? address.worktree
        return "db.\(what)/\(project)/\(address.name)"
    }

    func loadQueries() {
        if case .string(let text)? = app.uiState[key("draft")], editor.text.isEmpty {
            editor.setText(text)   // the text typed here last time
        }
        guard case .array(let items)? = app.uiState[queriesKey] else { return }
        sidebar.saved = items.compactMap { item in
            guard case .object(let fields) = item, case .string(let name)? = fields["name"],
                case .string(let sql)? = fields["sql"]
            else { return nil }
            return DatabaseSidebar.SavedQuery(name: name, sql: sql)
        }
    }

    /// Keeps the editor's text for the database once the workspace's databases are known, because the key names the
    /// project.
    func keepDraft() {
        draft.cancel()
        guard started else { return }
        app.uiState[key("draft")] = .string(editor.text)
    }

    private func storeQueries(_ list: [DatabaseSidebar.SavedQuery]) {
        sidebar.saved = list
        let value = JSONValue.array(list.map { .object(["name": .string($0.name), "sql": .string($0.sql)]) })
        Task { [app, queriesKey] in await app.uiState.save(queriesKey, value) }
    }

    /// Save Query… keeps the statement under a name, in the list's Queries.
    @objc func keepQuery() {
        let sql = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return NSSound.beep() }
        let initial = sql.split(whereSeparator: \.isNewline).first.map { String($0.prefix(40)) } ?? ""
        Task {
            guard
                let name = await prompt(
                    String(localized: "Save the query as"), "", initial: initial, action: String(localized: "Save"))
            else { return }
            let title = name.trimmingCharacters(in: .whitespaces)
            storeQueries(
                sidebar.saved.filter { $0.name != title } + [.init(name: title.isEmpty ? sql : title, sql: sql)])
        }
    }

    func openSaved(_ savedQuery: DatabaseSidebar.SavedQuery) {
        editor.setText(savedQuery.sql)
        Task { await leave(to: .query) }
    }

    func forget(_ savedQuery: DatabaseSidebar.SavedQuery) { storeQueries(sidebar.saved.filter { $0 != savedQuery }) }

    /// Shows the plan, as the engine gives it.
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
            await loadTables()   // a CREATE or a DROP changes the list of tables
        }
    }
}
