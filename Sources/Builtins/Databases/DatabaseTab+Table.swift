import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// A table's Data and its Structure. Data is a page of rows in the order and with the filters asked for; edits are
/// saved together, and the rows that an agent's last change touched are marked. Structure shows the columns, keys
/// and indexes; CREATE TABLE is copied from the table's menu and from Copy or Export Rows.
extension DatabaseTab {
    var current: DatabaseSchema.Table? { mode.table.flatMap { name in tables.first { $0.name == name } } }

    func showTable(_ name: String) async {
        arrange()
        sidebar.current = name
        guard part.selectedSegment == 0 else { return showStructure() }
        let info = current?.columns ?? [], primary = info.filter(\.primary).map(\.name)
        filters.use(columns: info.isEmpty ? grid.columns : info.map(\.name), engine: engine)
        var sql = "SELECT * FROM " + engine.table(name)
        let condition = filters.condition
        if !condition.isEmpty { sql += " WHERE " + condition }
        if !grid.orders.isEmpty {
            sql +=
                " ORDER BY "
                + grid.orders.map { engine.table($0.column) + ($0.ascending ? " ASC" : " DESC") }
                .joined(separator: ", ")
        }
        sql += " LIMIT \(Self.pageSize) OFFSET \(page * Self.pageSize)"
        startReading(name)
        let asked = page, order = Self.order(grid.orders)
        let result = await query(sql, limit: Self.pageSize, reading: name)
        await rowsWait.settled()
        // When another page, table, filter or order was asked for meanwhile, this answer is for the older ask. It is
        // checked after each wait.
        let still = { [weak self] in
            self.map {
                $0.page == asked && $0.sidebar.current == name && $0.filters.condition == condition
                    && Self.order($0.grid.orders) == order
            } ?? false
        }
        guard still() else { return }
        readingEnded()
        guard let result else { return }
        grid.editable = current?.kind != "view"   // a table without a key too: its rows are found by their values
        let again = grid.source?.table == name
        grid.source = (name, engine)
        let orders = grid.orders
        grid.show(columns: result.columns, rows: result.rows, info: info, keeping: again)
        if !again, let look = keptLook(name) { grid.apply(look) }   // as the table was left, in any tab
        grid.orders = orders
        keepLook()
        grid.indicate()
        empty.show(result.rows.isEmpty ? String(localized: "No Rows") : nil, symbol: "tablecells")
        arrange()
        // Turning pages keeps the count: the filter and the rows it counted are the same.
        let counting = name + " WHERE " + condition
        if asked == 0 || counted?.of != counting { counted = nil }
        if !condition.isEmpty, counted == nil {
            let rows = await count(name, condition)
            guard still() else { return }
            counted = rows.map { ($0, counting) }
        }
        pageChanged(shown: result.rows.count, ms: result.ms)
        await mark(name, primary: primary, still: still)
    }

    /// Shows "Reading orders…" in the foot only once a second has gone (`LoadingView.patience`), so a quick read
    /// changes nothing (`whileSlow`'s rule). A database elsewhere takes more than a moment, so with no rows on show yet
    /// its wait shows at once, over the grid. With no `table`, it is the user's statement that runs.
    func startReading(_ table: String? = nil) {
        reading?.cancel()
        if table != nil { takesEdits(false) }   // the answer replaces the rows, and edits made meanwhile with them
        let words = table.map { String(localized: "Reading \($0)…") } ?? String(localized: "Running the statement…")
        if grid.columns.isEmpty, elsewhere {
            empty.show(nil)
            rowsWait.show(words)
        }
        reading = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(LoadingView.patience)) } catch { return }
            self?.status.stringValue = words
            self?.busy.startAnimation(nil)
            self?.showStop(true)
        }
    }

    func readingEnded() {
        reading?.cancel()
        takesEdits(true)
        busy.stopAnimation(nil)
        showStop(false)
        rowsWait.show(nil)
    }

    /// Lets a table's rows take edits, or not while they are read again. A view's never do.
    func takesEdits(_ on: Bool) {
        let now = on && mode.table != nil && current?.kind != "view"
        guard grid.editable != now else { return }
        grid.editable = now
        grid.table.reloadData()   // the cells on screen take it
        arrange()   // and Add Row
    }

    /// An order as text, to tell two apart.
    static func order(_ orders: [(column: String, ascending: Bool)]) -> [String] {
        orders.map { $0.column + ($0.ascending ? " ASC" : " DESC") }
    }

    /// Counts how many rows the filter leaves. The server stops a count that takes too long.
    private func count(_ name: String, _ condition: String) async -> Int? {
        let sql = "SELECT count(*) FROM " + engine.table(name) + " WHERE " + condition
        let answer = await app.quiet(DatabaseQuery(worktreeId: address.worktree, database: address.name, sql: sql))
        return (answer?.rows.first?.first ?? nil).flatMap { Int($0) }
    }

    /// Shows "1–200 of ≈ 12 408 rows · filtered · 14 ms" in the foot, with ‹ › when there are more pages.
    func pageChanged(shown: Int, ms: Int) {
        let first = page * Self.pageSize
        // A page that isn't full is the last one, so the total is known, whatever the server's estimate says (0
        // before ANALYZE).
        let ended = shown < Self.pageSize
        let estimate = (filters.isActive ? nil : current?.rows).flatMap { $0 >= first + shown ? $0 : nil }
        let total = ended ? first + shown : counted?.rows ?? estimate
        let exact = ended || counted != nil || engine.isFile
        var words: [String] = [""]   // after the count, which is a label of its own
        if shown == 0 {
            rowCount.stringValue = String(localized: "No rows")
        } else {
            let range = "\((first + 1).formatted())–\((first + shown).formatted())"
            let all = total.map { (exact ? "" : "≈ ") + Self.rows($0) }   // "≈ 12 408 rows"
            rowCount.stringValue = all.map { String(localized: "\(range) of \($0)") } ?? range
        }
        if filters.isActive { words.append(String(localized: "filtered")) }
        if !grid.editable { words.append(String(localized: "a view: read only")) }
        if let bytes = current?.bytes {
            words.append(DesignKit.bytes(bytes, file: true))
        }
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

    /// Reads what the tab shows again. A table's unsaved edits are asked about first (`settleEdits`), as before each
    /// read in place that would drop them: a new order, filter or part.
    func refresh() {
        switch mode {
        case .table(let name):
            Task {
                guard await settleEdits() else { return }
                counted = nil
                await showTable(name)
            }
        case .run(let id): Task { await showRun(id) }
        case .query: Task { await loadTables() }
        }
    }

    func sorted(was: [(column: String, ascending: Bool)]) {
        guard let name = mode.table else { return }
        Task {
            guard await settleEdits() else {   // the edits stay, and so does the order they were made in
                grid.orders = was
                return grid.indicate()
            }
            page = 0
            await showTable(name)
        }
    }

    func filtered() {
        guard let name = mode.table else { return }
        Task {
            guard await settleEdits() else { return }
            page = 0
            await showTable(name)
        }
    }

    func toggleFilters() {
        filters.view.isHidden.toggle()
        if !filters.view.isHidden {
            filters.use(columns: current?.columns.map(\.name) ?? grid.columns, engine: engine)
        }
    }

    func toggleDetails() {
        details.view.isHidden.toggle()
        detailsClosed = details.view.isHidden
        if !detailsClosed { detailsChanged() }
    }

    /// Shows the table's data (0) or its structure (1), as the foot's Data / Structure does.
    func showPart(_ index: Int) {
        part.selectedSegment = index
        partChanged()
    }

    @objc func partChanged() {
        guard let name = mode.table else { return }
        Task {
            guard await settleEdits() else { return part.selectedSegment = 0 }   // Structure shows no edits
            await showTable(name)
        }
    }

    /// The Columns menu: show or hide each column, or show all of them again.
    func columnsMenu() {
        let menu = NSMenu()
        for column in grid.table.tableColumns.dropFirst() {
            guard let index = Int(column.identifier.rawValue), grid.columns.indices.contains(index) else { continue }
            menu.add(grid.columns[index]) { column.isHidden.toggle() }.state = column.isHidden ? .off : .on
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Show All")) { [weak self] in
            self?.grid.table.tableColumns.forEach { $0.isHidden = false }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: An agent's last change

    /// Marks the rows that the latest agent change here left, as RETURNING gave them, found again by their key.
    private func mark(_ name: String, primary: [String], still: () -> Bool) async {
        guard !primary.isEmpty else { return }
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs ?? []
        guard let last = Self.lastAgentChange(runs, to: name, in: address.name),
            let result = await app.quiet(DatabaseResultRead(worktreeId: address.worktree, id: last.id)) ?? nil
        else { return }
        guard still() else { return }   // the grid shows another page, table or filter now
        let theirs = primary.compactMap { result.columns.firstIndex(of: $0) }
        let mine = primary.compactMap { grid.columns.firstIndex(of: $0) }
        guard theirs.count == primary.count, mine.count == primary.count else { return }
        let keys = Set(result.rows.map { row in theirs.map { row.indices.contains($0) ? row[$0] ?? "" : "" } })
        grid.marked = Set(
            grid.rows.indices.filter { rowIndex in
                keys.contains(
                    mine.map { grid.rows[rowIndex].indices.contains($0) ? grid.rows[rowIndex][$0] ?? "" : "" })
            })
        guard !grid.marked.isEmpty else { return }
        grid.changed()
        let who = last.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "an agent")
        status.stringValue += " · " + String(localized: "\(grid.marked.count) changed by \(who) \(shortAgo(last.at))")
    }

    /// The latest change to `table` (`runs` is newest first), when an agent made it. When the user made a change
    /// since (an undo, an edit), there are no rows to mark as the agent's.
    static func lastAgentChange(_ runs: [DatabaseRun], to table: String, in database: String) -> DatabaseRun? {
        let short = table.split(separator: ".").last.map { $0.lowercased() } ?? table
        let last = runs.first {
            $0.database == database && $0.state == .done && ($0.changed ?? 0) > 0 && $0.sql.lowercased().contains(short)
        }
        return last?.session == nil ? nil : last
    }

    // MARK: Structure

    private func showStructure() {
        guard let table = current else { return }
        grid.editable = false
        grid.source = nil
        let rows = table.columns.map { column -> [String?] in
            [
                column.name, column.type, column.nullable ? String(localized: "yes") : String(localized: "no"),
                column.primary ? String(localized: "primary key") : "", column.references ?? ""
            ]
        }
        indexesText.stringValue = table.indexes.joined(separator: "\n")   // under the columns (`indexesBlock`)
        grid.show(
            columns: [
                String(localized: "column"), String(localized: "type"), String(localized: "null"),
                String(localized: "key"), String(localized: "refers to")
            ], rows: rows)
        empty.show(nil)
        let columns =
            table.columns.count == 1
            ? String(localized: "1 column") : String(localized: "\(table.columns.count) columns")
        let indexes =
            table.indexes.isEmpty
            ? nil
            : table.indexes.count == 1
                ? String(localized: "1 index") : String(localized: "\(table.indexes.count) indexes")
        status.stringValue = [columns, indexes].compactMap { $0 }.joined(separator: " · ")
        footChanged()
    }

    /// The block under Structure's columns that lists the table's indexes, one a line, with a line over it.
    func indexesBlock() -> NSStackView {
        let title = NSTextField.label(
            String(localized: "Indexes"), font: .ui(TextSize.caption, weight: .semibold), color: .secondaryLabelColor)
        indexesText.font = .uiMono(TextSize.caption)
        indexesText.isSelectable = true
        indexesText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSStackView(views: [title, indexesText])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Metrics.lineGap
        words.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        let line = NSBox()
        line.boxType = .separator
        let box = NSStackView(views: [line, words])
        box.orientation = .vertical
        box.spacing = 0
        for v in [line, words] { v.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
        box.isHidden = true
        return box
    }

    /// CREATE TABLE as the columns read, which is what an agent or a migration starts from.
    func definition(_ table: DatabaseSchema.Table) -> String {
        let lines =
            table.columns.map { column in
                "  " + engine.table(column.name) + " " + column.type
                    + (column.nullable ? "" : " NOT NULL")
                    + (column.target.map { " REFERENCES " + engine.table($0.table) + "(\($0.column))" }
                        ?? "")
            }
            + [table.columns.filter(\.primary).map { engine.table($0.name) }].filter { !$0.isEmpty }
            .map { "  PRIMARY KEY (" + $0.joined(separator: ", ") + ")" }
        return "CREATE TABLE " + engine.table(table.name) + " (\n" + lines.joined(separator: ",\n")
            + "\n);"
    }

    // MARK: Details

    /// Makes the right column follow the table, the selected row and this table's agent runs.
    func detailsChanged() {
        details.table = current
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
        // The details stay closed until a row is picked, because what they'd say of the table is on screen already.
        // Once the user closes them, they stay closed, and aren't built again for each row picked.
        if picked != nil, !detailsClosed { details.view.isHidden = false }
        guard !details.view.isHidden else { return }
        details.show(picked == nil ? nil : .row)
    }

    /// Applies a field edited in the details as the same edit in the row's cell.
    func editFromDetails(_ column: Int, _ value: String?) {
        guard let row = grid.selectedRows.first, grid.rows.indices.contains(row) else { return }
        let old = grid.rows[row].indices.contains(column) ? grid.rows[row][column] : nil
        grid.edits.set(row: row, column: column, to: value, was: old)
        grid.changed(rows: [row])
    }

    /// Follows a foreign key's arrow in a cell to the table it names, at that row.
    func followKey(_ column: String, _ value: String) {
        guard let target = current?.columns.first(where: { $0.name == column })?.target else { return }
        follow(target.table, target.column, value)
    }

    /// Shows `table` filtered to the row where `column` holds `value`.
    func follow(_ table: String, _ column: String, _ value: String) { Task { await followed(table, column, value) } }

    func followed(_ table: String, _ column: String, _ value: String) async {
        let target = tables.first { $0.name == table || $0.name.hasSuffix("." + table) }?.name ?? table
        guard await leave(to: .table(target)) else { return }   // Cancel keeps the table and its edits
        filters.add(column: column, op: .equal, value: value)
    }
}
