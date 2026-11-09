import AppKit
import Core
import DesignKit
import KelpKit

/// "db:<workspace>/<name>[?run=<id>]": a database's tables on the left; on the right a table's rows (with a filter,
/// cells to edit when it has a primary key), a run's rows (an agent's query, or the change it asks to make), or a
/// query of the user's own. Over it all, while an agent asks to change this database: who, how much, Deny / Allow.
@MainActor
final class DatabaseTab: NSObject, KelpKit.TabContent, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private enum Mode: Equatable {
        case table(String), run(String), query

        var isRun: Bool {
            if case .run = self { return true }
            return false
        }
    }

    let uri: String
    let view = NSView()
    var title: String { address.name }
    var icon: NSImage? { .symbol(DatabaseLook.symbol) }
    var isEdited: Bool { !grid.edits.isEmpty }

    private let app: AppModel
    private let address: DatabaseURI
    private var mode: Mode
    private var tables: [DatabaseSchema.Table] = []
    private let tableList = NSTableView()
    private let grid = ResultGrid()
    private let empty = EmptyStateView()
    private let heading = NSTextField(labelWithString: "")
    private let filter = NSSearchField()
    private let sqlText = NSTextField(wrappingLabelWithString: "")
    private let editor = NSTextView()
    private lazy var editorScroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let askBar = NSStackView()
    private let askText = NSTextField(labelWithString: "")
    private var asking: DatabaseRun?
    private lazy var watched = Watched(.databases, in: app)
    private lazy var run = NSButton(title: String(localized: "Run"), target: self, action: #selector(runQuery))
    private lazy var save = NSButton(title: "", target: self, action: #selector(saveEdits))
    private lazy var discard = NSButton(
        title: String(localized: "Discard"), target: self, action: #selector(discardEdits))
    private lazy var ask = NSButton(title: "", target: self, action: #selector(askAgent))

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        address = DatabaseURI(uri) ?? DatabaseURI(worktree: "", name: "")
        mode = address.run.map(Mode.run) ?? .query
        super.init()
        build()
        watched.key = address.worktree
        track(owner: self) { [app, address] in
            app.latest(DatabasesEvent.self, address.worktree)?.runs.filter { $0.database == address.name }
        } changed: { [weak self] _ in
            self?.runsChanged()
        }
        Task { await loadTables() }
        if case .run(let id) = mode { Task { await showRun(id) } }
    }

    func focus() { view.window?.makeFirstResponder(mode == .query ? editor : grid.scroll.documentView) }

    func close() async -> Bool {
        guard isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the changes to \(address.name)?")
        alert.informativeText = String(localized: "\(grid.edits.count) cells you edited aren't saved.")
        alert.addButton(withTitle: String(localized: "Close Without Saving"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    // MARK: Layout

    private func build() {
        let left = tableList.plainList("t")
        tableList.dataSource = self
        tableList.delegate = self
        tableList.target = self
        tableList.action = #selector(tablePicked)
        let newQuery = NSButton(title: String(localized: "New Query"), target: self, action: #selector(startQuery))
        newQuery.bezelStyle = .accessoryBarAction
        let leftFoot = Bar.foot([newQuery])
        let side = NSStackView(views: [left, leftFoot])
        side.orientation = .vertical
        side.spacing = 0
        side.widthAnchor.constraint(equalToConstant: 200).isActive = true

        heading.font = .ui(12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filter.placeholderString = String(localized: "Filter: a WHERE condition")
        filter.sendsWholeSearchString = true
        filter.target = self
        filter.action = #selector(filtered)
        run.keyEquivalent = "\r"
        run.keyEquivalentModifierMask = .command
        let bar = Bar.content([heading], [filter, run], stretching: filter)
        sqlText.font = .uiMono(11)
        sqlText.textColor = .secondaryLabelColor
        sqlText.maximumNumberOfLines = 3
        sqlText.lineBreakMode = .byTruncatingTail
        let sqlBox = NSStackView(views: [sqlText])
        sqlBox.edgeInsets = NSEdgeInsets(top: 6, left: Metrics.inset, bottom: 6, right: Metrics.inset)
        editor.font = .uiMono(12)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editor.autoresizingMask = [.width]
        editorScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        status.font = .uiDigits(11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        save.bezelStyle = .push
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        for button in [discard, ask] { button.bezelStyle = .accessoryBarAction }
        let foot = Bar.foot([status], [ask, discard, save])
        grid.onChange = { [weak self] in self?.footChanged() }

        buildAskBar()
        let right = NSStackView(views: [askBar, bar, sqlBox, editorScroll, grid.scroll, foot])
        right.orientation = .vertical
        right.spacing = 0
        right.detachesHiddenViews = true
        for v in [askBar, bar, sqlBox, editorScroll, grid.scroll, foot] {
            v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        grid.scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        side.setContentHuggingPriority(.required, for: .horizontal)
        let whole = NSStackView(views: [side, divider, right])
        whole.spacing = 0
        whole.alignment = .height
        whole.distribution = .fill
        whole.setHuggingPriority(.defaultLow, for: .horizontal)
        right.setContentHuggingPriority(.init(1), for: .horizontal)
        view.pin(whole)
        empty.place(in: grid.scroll)
        arrange()
    }

    private func buildAskBar() {
        askText.font = .ui(12, weight: .medium)
        askText.textColor = .textOrange
        askText.lineBreakMode = .byTruncatingTail
        askText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let show = NSButton(title: String(localized: "Show Rows"), target: self, action: #selector(showAsked))
        let deny = NSButton(title: String(localized: "Deny"), target: self, action: #selector(denyAsked))
        let allow = NSButton(title: String(localized: "Allow"), target: self, action: #selector(allowAsked))
        for button in [show, deny, allow] { button.bezelStyle = .accessoryBarAction }
        let mark = NSImageView(image: .symbol("exclamationmark.bubble"))
        mark.contentTintColor = .textOrange
        for v in [mark, askText, NSView(), show, deny, allow] { askBar.addArrangedSubview(v) }
        askBar.spacing = Metrics.gapWide
        askBar.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        askBar.heightAnchor.constraint(equalToConstant: Metrics.contentBar).isActive = true
        askBar.wantsLayer = true
        askBar.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        askBar.isHidden = true
    }

    /// What each mode shows: a table its filter; a run its SQL; a query its editor and Run.
    private func arrange() {
        filter.isHidden = mode == .query || mode.isRun
        run.isHidden = mode != .query
        sqlText.superview?.isHidden = !mode.isRun
        editorScroll.isHidden = mode != .query
        footChanged()
    }

    // MARK: Tables

    private func loadTables() async {
        let (schema, error) = await app.tryCall(
            DatabaseSchemaRead(worktreeId: address.worktree, database: address.name))
        guard let schema else {
            empty.showError(String(localized: "Can't read \(address.name)"), text: error)
            return
        }
        tables = schema.tables
        tableList.reloadData()
        if mode == .query, address.run == nil, let first = tables.first {
            mode = .table(first.name)
            await showTable(first.name)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tables.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let t = tables[row]
        let icon = NSImageView(image: .symbol("tablecells"))
        icon.symbolConfiguration = .chrome(Metrics.iconSmall)
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: t.name)
        name.font = .ui(12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = NSTextField(labelWithString: t.rows.map { $0.formatted() } ?? "")
        count.font = .uiDigits(11)
        count.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, name, NSView(), count])
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return stack
    }

    @objc private func tablePicked() {
        guard tables.indices.contains(tableList.clickedRow) else { return }
        let name = tables[tableList.clickedRow].name
        Task { await leave(to: .table(name)) }
    }

    /// Away from edits only once they're saved or dropped.
    private func leave(to next: Mode) async {
        if isEdited, await !close() { return }
        mode = next
        filter.stringValue = ""
        switch next {
        case .table(let name): await showTable(name)
        case .run(let id): await showRun(id)
        case .query: startedQuery()
        }
    }

    private func showTable(_ name: String) async {
        arrange()
        heading.stringValue = name
        let primary = tables.first { $0.name == name }?.columns.filter(\.primary).map(\.name) ?? []
        let engine = database?.engine ?? .sqlite
        var sql = "SELECT * FROM " + DatabaseEdits.name(name, engine)
        let where_ = filter.stringValue.trimmingCharacters(in: .whitespaces)
        if !where_.isEmpty { sql += " WHERE " + where_ }
        sql += " LIMIT \(ResultGrid.shown)"
        guard let result = await query(sql) else { return }
        grid.editable = !primary.isEmpty
        grid.show(columns: result.columns, rows: result.rows)
        empty.show(result.rows.isEmpty ? String(localized: "No Rows") : nil, symbol: "tablecells")
        let count = tables.first { $0.name == name }?.rows
        status.stringValue = [
            String(localized: "\(result.rows.count) rows") + (count.map { " " + String(localized: "of \($0)") } ?? ""),
            primary.isEmpty ? String(localized: "no primary key: read only") : nil
        ].compactMap { $0 }.joined(separator: " · ")
        footChanged()
    }

    @objc private func filtered() {
        if case .table(let name) = mode { Task { await showTable(name) } }
    }

    // MARK: Runs

    private var database: DatabaseInfo? {
        app.latest(DatabasesEvent.self, address.worktree)?.databases.first { $0.name == address.name }
    }

    private func record(_ id: String) -> DatabaseRun? {
        app.latest(DatabasesEvent.self, address.worktree)?.runs.first { $0.id == id }
    }

    private func showRun(_ id: String) async {
        arrange()
        let record = record(id)
        let who = record?.session.flatMap(app.session).map { app.catalog.displayName($0) } ?? String(localized: "You")
        heading.stringValue = [who, record.map { shortAgo($0.at) }].compactMap { $0 }.joined(separator: " · ")
        sqlText.stringValue = record?.sql ?? ""
        let result = await app.quiet(DatabaseResultRead(worktreeId: address.worktree, id: id)) ?? nil
        grid.editable = false
        grid.show(columns: result?.columns ?? [], rows: result?.rows ?? [])
        if let error = record?.error, record?.state != .asks {
            empty.showError(Self.stateTitle(record?.state ?? .failed), text: error)
        } else if result == nil {
            empty.show(
                String(localized: "Not Kept"), symbol: "clock",
                text: String(localized: "Kelp keeps the rows of the latest runs only."))
        } else {
            empty.show(
                result?.rows.isEmpty == true && result?.columns.isEmpty == false ? String(localized: "No Rows") : nil)
        }
        status.stringValue = record.map(Self.summary) ?? ""
        footChanged()
    }

    static func stateTitle(_ state: DatabaseRun.State) -> String {
        switch state {
        case .denied: String(localized: "Denied")
        case .refused: String(localized: "Refused")
        default: String(localized: "Failed")
        }
    }

    /// "200 rows · 12 ms", "1 204 rows would change", "3 rows changed".
    static func summary(_ run: DatabaseRun) -> String {
        switch run.state {
        case .asks:
            return run.changed.map { String(localized: "\($0) rows would change: shown as they would be") }
                ?? String(localized: "Waits for your answer")
        case .done:
            let what =
                run.changed.map { String(localized: "\($0) rows changed") }
                ?? String(localized: "\(run.rows ?? 0) rows")
            return [what, run.ms.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · ")
        default: return run.error ?? ""
        }
    }

    /// The runs of this database changed: the bar follows the one that asks, and a run shown takes its new state.
    private func runsChanged() {
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs.filter { $0.database == address.name } ?? []
        let was = asking
        asking = runs.first { $0.state == .asks }
        askBar.isHidden = asking == nil
        if let asking {
            let who =
                asking.session.flatMap(app.session).map { app.catalog.displayName($0) } ?? String(localized: "An agent")
            let what =
                asking.changed.map { String(localized: "\(who) wants to change \($0) rows in \(address.name)") }
                ?? String(localized: "\(who) wants to change \(address.name)")
            askText.stringValue = what
            askText.toolTip = asking.sql
        }
        if case .run(let id) = mode, was?.id == id, asking?.id != id { Task { await showRun(id) } }
    }

    @objc private func showAsked() {
        guard let asking else { return }
        Task { await leave(to: .run(asking.id)) }
    }
    @objc private func allowAsked() { answer("allow") }
    @objc private func denyAsked() { answer("deny") }
    private func answer(_ action: String) {
        guard let session = asking?.session else { return }
        Notifications.answer(app, session, action, question: app.session(session)?.summary)
    }

    // MARK: A query of the user's own

    @objc private func startQuery() { Task { await leave(to: .query) } }

    private func startedQuery() {
        arrange()
        heading.stringValue = String(localized: "Query")
        if editor.string.isEmpty, let first = tables.first {
            editor.string =
                "SELECT * FROM " + DatabaseEdits.name(first.name, database?.engine ?? .sqlite) + " LIMIT 100"
        }
        grid.editable = false
        grid.show(columns: [], rows: [])
        empty.show(
            String(localized: "Run a Statement"), symbol: "play",
            text: String(localized: "⌘↩ runs it. One statement at a time."))
        status.stringValue = ""
        view.window?.makeFirstResponder(editor)
    }

    @objc private func runQuery() {
        let sql = editor.string
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

    /// The user's statement, as theirs: a change runs without a question. Its error shows where the rows would.
    private func query(_ sql: String) async -> QueryResult? {
        let (result, error) = await app.tryCall(
            DatabaseQuery(worktreeId: address.worktree, database: address.name, sql: sql, limit: ResultGrid.shown))
        if let error {
            grid.show(columns: [], rows: [])
            empty.showError(String(localized: "\(address.name) said no"), text: error)
            status.stringValue = ""
        }
        return result
    }

    // MARK: Edits and the agent

    private func footChanged() {
        let edits = grid.edits.count
        save.title = String(localized: "Save \(edits) Changes")
        save.isHidden = edits == 0
        discard.isHidden = edits == 0
        let picked = grid.selectedRows.count, agent = agentToAsk
        ask.isHidden = picked == 0 || agent == nil
        if let agent { ask.title = String(localized: "Ask \(app.catalog.displayName(agent)) About \(picked) Rows") }
    }

    /// The chat a run came from, else the one in focus, else the workspace's last agent still there.
    private var agentToAsk: Session? {
        if case .run(let id) = mode, let sid = record(id)?.session, let s = app.session(sid), s.status != .exited {
            return s
        }
        if let sid = app.workbench.focusedSession, let s = app.session(sid), s.worktreeId == address.worktree,
            s.agent != nil
        {
            return s
        }
        return app.sessions.last { $0.worktreeId == address.worktree && $0.agent != nil && $0.status != .exited }
    }

    @objc private func askAgent() {
        guard let agent = agentToAsk else { return }
        let picked = Array(grid.selectedRows.prefix(50))
        let source =
            if case .table(let name) = mode { String(localized: "the table \(name)") } else { sqlText.stringValue }
        let text = "Rows of \(address.name) (\(source)):\n" + grid.text(picked) + "\n"
        Task {
            guard await app.call(SessionSend(id: agent.id, text: text, enter: false)) != nil else { return }
            app.workbench.focus(session: agent.id)
        }
    }

    @objc private func discardEdits() { grid.discard() }

    /// The edits as UPDATEs, shown before they run; each runs as the user's, one by one.
    @objc private func saveEdits() {
        guard case .table(let name) = mode, let db = database,
            let table = tables.first(where: { $0.name == name }),
            let statements = grid.edits.statements(
                table: name, engine: db.engine, columns: grid.columns,
                primary: table.columns.filter(\.primary).map(\.name),
                rows: grid.rows)
        else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Save \(grid.edits.count) changes to \(name)?")
            alert.informativeText = statements.joined(separator: ";\n") + ";"
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            for sql in statements {
                guard await query(sql) != nil else { return }   // the first that fails stops the rest, and says why
            }
            grid.edits.clear()
            await showTable(name)
        }
    }
}
