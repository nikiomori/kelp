import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// A table's Data (a page of rows in the order and with the filters asked for, edits saved together, the rows an
/// agent's last change touched marked) and its Structure (columns, keys, indexes; CREATE TABLE in the details).
extension DatabaseTab {
    var current: DatabaseSchema.Table? { mode.table.flatMap { name in tables.first { $0.name == name } } }

    func showTable(_ name: String) async {
        arrange()
        sidebar.current = name
        guard part.selectedSegment == 0 else { return showStructure() }
        let info = current?.columns ?? [], primary = info.filter(\.primary).map(\.name)
        filters.use(columns: info.isEmpty ? grid.columns : info.map(\.name), engine: engine)
        var sql = "SELECT * FROM " + DatabaseEdits.name(name, engine)
        let condition = filters.condition
        if !condition.isEmpty { sql += " WHERE " + condition }
        if !grid.orders.isEmpty {
            sql +=
                " ORDER BY "
                + grid.orders.map { DatabaseEdits.name($0.column, engine) + ($0.ascending ? " ASC" : " DESC") }
                .joined(separator: ", ")
        }
        sql += " LIMIT \(Self.pageSize) OFFSET \(page * Self.pageSize)"
        startReading()
        let result = await query(sql, limit: Self.pageSize)
        reading?.cancel()
        busy.stopAnimation(nil)
        guard let result else { return }
        grid.editable = current?.kind != "view"   // a table without a key too: its rows found by their values
        grid.source = (name, engine)
        let orders = grid.orders
        grid.show(columns: result.columns, rows: result.rows, info: info)
        grid.orders = orders
        grid.indicate()
        empty.show(result.rows.isEmpty ? String(localized: "No Rows") : nil, symbol: "tablecells")
        arrange()
        counted = nil
        if !condition.isEmpty { await count(name, condition) }
        pageChanged(shown: result.rows.count, ms: result.ms)
        await mark(name, primary: primary)
    }

    /// "Reading…" in the foot only once half a second has gone: a quick read doesn't flicker.
    func startReading() {
        reading?.cancel()
        reading = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.status.stringValue = String(localized: "Reading…")
            self?.busy.startAnimation(nil)
        }
    }

    /// With a filter on, how many rows it leaves: counted (the server stops a count that takes too long).
    private func count(_ name: String, _ condition: String) async {
        let sql = "SELECT count(*) FROM " + DatabaseEdits.name(name, engine) + " WHERE " + condition
        let answer = await app.quiet(DatabaseQuery(worktreeId: address.worktree, database: address.name, sql: sql))
        counted = (answer?.rows.first?.first ?? nil).flatMap { Int($0) }
    }

    /// "1–200 of ≈ 12 408 rows · filtered · 14 ms", ‹ › where there's more.
    func pageChanged(shown: Int, ms: Int) {
        let first = page * Self.pageSize
        // A page not full is the last one: the total is known, whatever the server's estimate says (0 before ANALYZE)
        let ended = shown < Self.pageSize
        let estimate = (filters.isActive ? nil : current?.rows).flatMap { $0 >= first + shown ? $0 : nil }
        let total = ended ? first + shown : counted ?? estimate
        let exact = ended || counted != nil || engine.isFile
        var words: [String] = []
        if shown == 0 {
            words.append(String(localized: "No rows"))
        } else {
            let range = "\((first + 1).formatted())–\((first + shown).formatted())"
            words.append(
                total.map { range + " " + String(localized: "of") + " " + (exact ? "" : "≈ ") + Self.rows($0) }
                    ?? range)
        }
        if filters.isActive { words.append(String(localized: "filtered")) }
        if !grid.editable { words.append(String(localized: "a view: read only")) }
        words.append(Self.took(ms))
        status.stringValue = words.joined(separator: " · ")
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

    func filtered() {
        guard let name = mode.table else { return }
        page = 0
        Task { await showTable(name) }
    }

    func toggleFilters() {
        filters.view.isHidden.toggle()
        if !filters.view.isHidden {
            filters.use(columns: current?.columns.map(\.name) ?? grid.columns, engine: engine)
        }
    }

    @objc func partChanged() {
        guard let name = mode.table else { return }
        Task { await showTable(name) }
    }

    /// Columns: each one shown or hidden, and all back.
    func columnsMenu() {
        let menu = NSMenu()
        for column in grid.table.tableColumns.dropFirst() {
            guard let i = Int(column.identifier.rawValue), grid.columns.indices.contains(i) else { continue }
            menu.add(grid.columns[i]) { column.isHidden.toggle() }.state = column.isHidden ? .off : .on
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Show All")) { [weak self] in
            self?.grid.table.tableColumns.forEach { $0.isHidden = false }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: An agent's last change

    /// The rows the latest change an agent made here left (kept as RETURNING gave them), found again by their key.
    private func mark(_ name: String, primary: [String]) async {
        guard !primary.isEmpty else { return }
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs ?? []
        let short = name.split(separator: ".").last.map { $0.lowercased() } ?? name
        guard
            let last = runs.first(where: {
                $0.database == address.name && $0.session != nil && $0.state == .done && ($0.changed ?? 0) > 0
                    && $0.sql.lowercased().contains(short)
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
        var rows = t.columns.map { c -> [String?] in
            [c.name, c.type, c.nullable ? "yes" : "no", c.primary ? "primary key" : "", c.references ?? ""]
        }
        if !t.indexes.isEmpty { rows += [["", "", "", "", ""]] + t.indexes.map { ["index", $0, "", "", ""] } }
        grid.show(
            columns: [
                String(localized: "column"), String(localized: "type"), String(localized: "null"),
                String(localized: "key"), String(localized: "refers to")
            ], rows: rows)
        empty.show(nil)
        let columns =
            t.columns.count == 1 ? String(localized: "1 column") : String(localized: "\(t.columns.count) columns")
        let indexes =
            t.indexes.isEmpty
            ? nil
            : t.indexes.count == 1 ? String(localized: "1 index") : String(localized: "\(t.indexes.count) indexes")
        status.stringValue = [columns, indexes].compactMap { $0 }.joined(separator: " · ")
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

    // MARK: Details

    /// The right column follows the table, the selected row and this table's agent runs.
    func detailsChanged() {
        details.table = current
        details.definition = current.map(definition) ?? ""
        let picked = grid.selectedRows.first
        details.row = picked.map { ($0, grid.columns, grid.rows[$0]) }
        details.editable = grid.editable && mode.table != nil && part.selectedSegment == 0
        let short = mode.table.flatMap { $0.split(separator: ".").last.map { $0.lowercased() } }
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs ?? []
        details.runs = runs.filter { run in
            run.database == address.name && run.session != nil
                && short.map { run.sql.lowercased().contains($0) } != false
        }
        details.agentName = agentToAsk.map { app.catalog.name($0.agent) }
        details.show(picked == nil ? nil : .row)
    }

    /// A field edited in the details: the same edit as in its cell.
    func editFromDetails(_ column: Int, _ value: String?) {
        guard let row = grid.selectedRows.first, grid.rows.indices.contains(row) else { return }
        let old = grid.rows[row].indices.contains(column) ? grid.rows[row][column] : nil
        grid.edits.set(row: row, column: column, to: value, was: old)
        grid.changed(rows: [row])
    }

    /// A foreign key's arrow in a cell: the table it names, at that row.
    func followKey(_ column: String, _ value: String) {
        guard let ref = current?.columns.first(where: { $0.name == column })?.references else { return }
        let p = ref.split(separator: ".")
        guard p.count == 2 else { return }
        follow(String(p[0]), String(p[1]), value)
    }

    /// That table, filtered to that row.
    func follow(_ table: String, _ column: String, _ value: String) {
        let target = tables.first { $0.name == table || $0.name.hasSuffix("." + table) }?.name ?? table
        Task {
            await leave(to: .table(target))
            filters.add(column: column, op: .equal, value: value)
        }
    }

    // MARK: Copy and export

    func copyMenu() {
        let menu = NSMenu()
        let picked = grid.selectedRows.isEmpty ? Array(grid.rows.indices) : grid.selectedRows
        let what = grid.selectedRows.isEmpty ? String(localized: "the Page") : Self.rows(picked.count).capitalizedFirst
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
            status.stringValue += " · " + Self.rows(done.changed ?? 0) + " " + String(localized: "saved")
            // Each statement is one row; fewer means a row wasn't where it was read (changed meanwhile)
            if let changed = done.changed, changed < statements.count {
                Banner.show(
                    String(
                        localized:
                            "\(statements.count - changed) of the rows weren’t found as they were read: someone changed them meanwhile. Reloaded."
                    ))
            }
        }
    }
}
