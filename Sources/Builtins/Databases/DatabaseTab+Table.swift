import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// A table's Data (a page of rows in the order and with the filter asked for, edits saved together, the rows an
/// agent's last change touched marked) and its Structure (columns, keys, indexes, a CREATE TABLE to copy).
extension DatabaseTab {
    var current: DatabaseSchema.Table? { mode.table.flatMap { name in tables.first { $0.name == name } } }

    func showTable(_ name: String) async {
        arrange()
        heading.stringValue = name
        guard part.selectedSegment == 0 else { return showStructure() }
        let info = current?.columns ?? [], primary = info.filter(\.primary).map(\.name)
        var sql = "SELECT * FROM " + DatabaseEdits.name(name, engine)
        let condition = filter.stringValue.trimmingCharacters(in: .whitespaces)
        if !condition.isEmpty { sql += " WHERE " + condition }
        if let order = grid.order {
            sql += " ORDER BY " + DatabaseEdits.name(order.column, engine) + (order.ascending ? " ASC" : " DESC")
        }
        sql += " LIMIT \(Self.pageSize) OFFSET \(page * Self.pageSize)"
        guard let result = await query(sql, limit: Self.pageSize) else { return }
        grid.editable = !primary.isEmpty
        grid.source = (name, engine)
        let order = grid.order
        grid.show(columns: result.columns, rows: result.rows, info: info)
        grid.order = order
        empty.show(result.rows.isEmpty ? String(localized: "No Rows") : nil, symbol: "tablecells")
        arrange()
        counted = nil
        if !condition.isEmpty { await count(name, condition) }
        pageChanged(shown: result.rows.count)
        await mark(name, primary: primary)
    }

    /// With a filter on, how many rows it leaves: counted (the server stops a count that takes too long).
    private func count(_ name: String, _ condition: String) async {
        let sql = "SELECT count(*) FROM " + DatabaseEdits.name(name, engine) + " WHERE " + condition
        let answer = await app.quiet(DatabaseQuery(worktreeId: address.worktree, database: address.name, sql: sql))
        counted = (answer?.rows.first?.first ?? nil).flatMap { Int($0) }
    }

    /// "201–400 of ≈ 1 204 000 · 14 ms", ‹ › where there's more.
    func pageChanged(shown: Int) {
        let first = page * Self.pageSize
        let total = counted ?? (filter.stringValue.isEmpty ? current?.rows : nil)
        let exact = counted != nil || engine.isFile
        let of = total.map { String(localized: "of") + " " + (exact ? "" : "≈ ") + $0.formatted() } ?? ""
        let range =
            shown == 0 ? String(localized: "No rows") : "\((first + 1).formatted())–\((first + shown).formatted())"
        status.stringValue =
            [range, of].filter { !$0.isEmpty }.joined(separator: " ")
            + (grid.editable ? "" : " · " + String(localized: "no primary key: read only"))
        previous.isEnabled = page > 0
        next.isEnabled = shown == Self.pageSize && (total.map { first + shown < $0 } ?? true)
    }

    func turn(_ by: Int) {
        guard let name = mode.table, !isEdited else { return NSSound.beep() }
        page = max(0, page + by)
        Task { await showTable(name) }
    }

    func refresh() {
        switch mode {
        case .table(let name): Task { await showTable(name) }
        case .run(let id): Task { await showRun(id) }
        case .query: Task { await loadTables() }
        }
    }

    func sorted() {
        guard let name = mode.table else { return }
        page = 0
        Task { await showTable(name) }
    }

    @objc func filtered() {
        guard let name = mode.table else { return }
        page = 0
        Task { await showTable(name) }
    }

    /// From a cell's menu: the condition in the filter, and the rows it leaves.
    func filterBy(_ condition: String) {
        filter.stringValue = condition
        filtered()
    }

    @objc func partChanged() {
        guard let name = mode.table else { return }
        Task { await showTable(name) }
    }

    // MARK: An agent's last change

    /// The rows the latest change an agent made here left (kept as RETURNING gave them), found again by their key.
    private func mark(_ name: String, primary: [String]) async {
        guard !primary.isEmpty else { return }
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs ?? []
        guard
            let last = runs.first(where: {
                $0.database == address.name && $0.session != nil && $0.state == .done && ($0.changed ?? 0) > 0
                    && $0.sql.lowercased().contains(name.split(separator: ".").last.map { $0.lowercased() } ?? name)
            }),
            let result = await app.quiet(DatabaseResultRead(worktreeId: address.worktree, id: last.id)) ?? nil
        else { return }
        let theirs = primary.compactMap { result.columns.firstIndex(of: $0) }
        let mine = primary.compactMap { grid.columns.firstIndex(of: $0) }
        guard theirs.count == primary.count, mine.count == primary.count else { return }
        let keys = Set(result.rows.map { row in theirs.map { row.indices.contains($0) ? row[$0] ?? "" : "" } })
        grid.marked = Set(
            grid.rows.indices.filter { r in
                keys.contains(mine.map { grid.rows[r].indices.contains($0) ? grid.rows[r][$0] ?? "" : "" })
            })
        guard !grid.marked.isEmpty else { return }
        grid.changed()
        let who = last.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "an agent")
        status.stringValue += " · ▍" + String(localized: "\(grid.marked.count) changed by \(who) \(shortAgo(last.at))")
    }

    // MARK: Structure

    private func showStructure() {
        guard let t = current else { return }
        grid.editable = false
        grid.source = nil
        let rows = t.columns.map { c -> [String?] in
            [c.name, c.type, c.nullable ? "yes" : "no", c.primary ? "primary" : "", c.references ?? ""]
        }
        grid.show(
            columns: [
                String(localized: "column"), String(localized: "type"), String(localized: "null"),
                String(localized: "key"), String(localized: "refers to")
            ], rows: rows)
        empty.show(nil)
        let indexes = t.indexes.map { String(localized: "index") + " " + $0 }
        status.stringValue = ([String(localized: "\(t.columns.count) columns")] + indexes).joined(separator: " · ")
        status.toolTip = t.indexes.joined(separator: "\n")
        footChanged()
    }

    /// CREATE TABLE as the columns read: what an agent or a migration starts from.
    func definition(_ t: DatabaseSchema.Table) -> String {
        let lines =
            t.columns.map { c in
                "  " + DatabaseEdits.name(c.name, engine) + " " + c.type + (c.nullable ? "" : " NOT NULL")
                    + (c.references.map { r in
                        let p = r.split(separator: ".")
                        return p.count == 2
                            ? " REFERENCES " + DatabaseEdits.name(String(p[0]), engine) + "(\(p[1]))" : ""
                    } ?? "")
            }
            + [t.columns.filter(\.primary).map { DatabaseEdits.name($0.name, engine) }].filter { !$0.isEmpty }
            .map { "  PRIMARY KEY (" + $0.joined(separator: ", ") + ")" }
        return "CREATE TABLE " + DatabaseEdits.name(t.name, engine) + " (\n" + lines.joined(separator: ",\n") + "\n);"
    }

    // MARK: Copy and export

    func copyMenu() {
        let menu = NSMenu()
        if let t = current, part.selectedSegment == 1 {
            menu.add(String(localized: "Copy CREATE TABLE")) { [weak self] in
                if let self { copyText(definition(t)) }
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let picked = grid.selectedRows.isEmpty ? Array(grid.rows.indices) : grid.selectedRows
        let what = grid.selectedRows.isEmpty ? String(localized: "the Page") : String(localized: "\(picked.count) Rows")
        for format in ResultText.Format.allCases {
            menu.add(String(localized: "Copy \(what) as \(format.rawValue)")) { [weak self] in
                guard let self else { return }
                copyText(text(format, picked))
            }
        }
        menu.addItem(.separator())
        for format in [ResultText.Format.csv, .json] {
            menu.add(String(localized: "Export \(what) as \(format.rawValue)…")) { [weak self] in
                self?.export(format, picked)
            }
        }
        if let t = current {
            menu.addItem(.separator())
            menu.add(String(localized: "Copy CREATE TABLE")) { [weak self] in
                if let self { copyText(definition(t)) }
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func text(_ format: ResultText.Format, _ picked: [Int]) -> String {
        ResultText.text(format, grid.columns, picked.map { grid.rows[$0] }, table: mode.table, engine: engine)
    }

    /// Saved where the user says: a file of their own choosing, not the project's.
    private func export(_ format: ResultText.Format, _ picked: [Int]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (mode.table ?? address.name) + "." + format.fileExtension
        let body = text(format, picked)
        Task {
            guard await runSheet(panel) == .OK, let url = panel.url else { return }
            do { try body.write(to: url, atomically: true, encoding: .utf8) } catch {
                Banner.show(String(localized: "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }
    }

    // MARK: The row's inspector

    func toggleInspector() {
        inspector.view.isHidden.toggle()
        if !inspector.view.isHidden { inspect() }
    }

    func inspect() {
        let row = grid.selectedRows.first
        inspector.show(
            row: row, columns: grid.columns, values: row.map { grid.rows[$0] } ?? [],
            info: Dictionary((current?.columns ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// A foreign key's value: that table, filtered to that row.
    func follow(_ table: String, _ column: String, _ value: String) {
        let target = tables.first { $0.name == table || $0.name.hasSuffix("." + table) }?.name ?? table
        Task {
            await leave(to: .table(target))
            filterBy(ResultText.condition(column, value, equal: true, engine: engine))
        }
    }

    // MARK: Edits

    @objc func discardEdits() { grid.discard() }

    /// What saving would run, before it runs.
    @objc func showEdits() {
        guard let statements = pending() else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(statements.count) statements, in one transaction")
        alert.informativeText = statements.joined(separator: ";\n") + ";"
        alert.addButton(withTitle: String(localized: "Copy"))
        alert.addButton(withTitle: String(localized: "Close"))
        Task { if await runSheet(alert) == .alertFirstButtonReturn { copyText(alert.informativeText) } }
    }

    private func pending() -> [String]? {
        guard let name = mode.table, let t = current else { return nil }
        return grid.edits.statements(
            table: name, engine: engine, columns: grid.columns, primary: t.columns.filter(\.primary).map(\.name),
            rows: grid.rows)
    }

    /// All of it in one transaction (`db.apply`); a production database asks first, in words.
    @objc func saveEdits() {
        guard let name = mode.table, let statements = pending(), !statements.isEmpty else { return }
        Task {
            if database?.production == true {
                let alert = NSAlert()
                alert.messageText = String(localized: "Change \(address.name)? It’s production.")
                alert.informativeText = statements.joined(separator: ";\n") + ";"
                alert.addButton(withTitle: String(localized: "Change Production"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            }
            let (done, error) = await app.tryCall(
                DatabaseApply(worktreeId: address.worktree, database: address.name, statements: statements))
            guard let done else {
                Banner.show(String(localized: "Nothing saved: \(error ?? "")"))
                return
            }
            grid.edits.clear()
            await showTable(name)
            status.stringValue += " · " + String(localized: "\(done.changed ?? 0) rows saved")
        }
    }
}
