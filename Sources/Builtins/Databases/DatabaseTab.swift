import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// "db:<workspace>/<name>[?run=<id>|?table=<name>]". On the left the database's tables, New Query and the latest runs
/// (anyone's). On the right a table, as Data (pages of rows with their types, an order, a filter, edits saved together,
/// a row's inspector) or Structure (its columns, keys and indexes); a run's rows (an agent's query, or the change it
/// asks to make); or a query of the user's own in Kelp's editor. Over it all, while an agent asks to change this
/// database: who, how much, Deny / Allow.
@MainActor
final class DatabaseTab: NSObject, KelpKit.TabContent, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    enum Mode: Equatable {
        case table(String), run(String), query

        var isRun: Bool {
            if case .run = self { return true }
            return false
        }
        var table: String? {
            if case .table(let name) = self { return name }
            return nil
        }
    }
    /// The left list: the tables, then the latest runs.
    enum Item {
        case section(String), table(DatabaseSchema.Table), newQuery, run(DatabaseRun)
    }

    let uri: String
    let view = NSView()
    var title: String { address.table.map { "\($0) · \(address.name)" } ?? address.name }
    var icon: NSImage? { .symbol(DatabaseLook.symbol) }
    var isEdited: Bool { !grid.edits.isEmpty }

    let app: AppModel
    let address: DatabaseURI
    var mode: Mode
    var tables: [DatabaseSchema.Table] = []
    var items: [Item] = []
    let tableList = NSTableView()
    let grid = ResultGrid()
    let inspector = RowInspector()
    let empty = EmptyStateView()
    let heading = NSTextField(labelWithString: "")
    let part = NSSegmentedControl(
        labels: [String(localized: "Data"), String(localized: "Structure")], trackingMode: .selectOne, target: nil,
        action: nil)
    let filter = NSSearchField()
    let sqlText = NSTextField(wrappingLabelWithString: "")
    lazy var editor = CodeEditor(text: "", url: URL(fileURLWithPath: "/query.sql"))
    let status = NSTextField(labelWithString: "")
    let askBar = NSStackView()
    let askText = NSTextField(labelWithString: "")
    var asking: DatabaseRun?
    /// The user picked what to show: the first table, shown once the list is read, no longer takes over.
    var chosen = false
    /// The page of a table's rows shown, and how many a page holds.
    var page = 0
    static let pageSize = 200
    /// Rows the table has with the filter on, when it was counted (nil: the planner's guess, or none).
    var counted: Int?
    lazy var watched = Watched(.databases, in: app)
    lazy var run = NSButton(title: String(localized: "Run"), target: self, action: #selector(runQuery))
    lazy var explain = NSButton(title: String(localized: "Explain"), target: self, action: #selector(explainQuery))
    lazy var save = NSButton(title: "", target: self, action: #selector(saveEdits))
    lazy var showSQL = NSButton(title: String(localized: "Show SQL"), target: self, action: #selector(showEdits))
    lazy var discard = NSButton(
        title: String(localized: "Discard"), target: self, action: #selector(discardEdits))
    lazy var ask = NSButton(title: "", target: self, action: #selector(askAgent))
    lazy var previous = IconButton(.symbol("chevron.left"), tip: String(localized: "Previous Rows")) { [weak self] in
        self?.turn(-1)
    }
    lazy var next = IconButton(.symbol("chevron.right"), tip: String(localized: "Next Rows")) { [weak self] in
        self?.turn(1)
    }
    lazy var addRow = IconButton(.symbol("plus"), tip: String(localized: "Add a Row")) { [weak self] in
        self?.grid.addRow()
    }
    lazy var reload = IconButton(.symbol("arrow.clockwise"), tip: String(localized: "Read Again")) { [weak self] in
        self?.refresh()
    }
    lazy var showInspector = IconButton(.symbol("sidebar.right"), tip: String(localized: "Show the Row (Space)")) {
        [weak self] in self?.toggleInspector()
    }
    lazy var copyAs = IconButton(.symbol("doc.on.doc"), tip: String(localized: "Copy or Export Rows")) { [weak self] in
        self?.copyMenu()
    }

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

    func focus() { view.window?.makeFirstResponder(mode == .query ? editor.textView : grid.table) }

    func close() async -> Bool {
        guard isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save the changes to \(address.name)?")
        alert.informativeText = String(localized: "\(grid.edits.count) changes you made aren't saved.")
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
        tableList.action = #selector(listPicked)
        left.widthAnchor.constraint(equalToConstant: 210).isActive = true

        heading.font = .ui(12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        part.selectedSegment = 0
        part.target = self
        part.action = #selector(partChanged)
        part.controlSize = .small
        part.setContentHuggingPriority(.required, for: .horizontal)
        filter.placeholderString = String(localized: "Filter: a WHERE condition")
        filter.sendsWholeSearchString = true
        filter.target = self
        filter.action = #selector(filtered)
        filter.recentsAutosaveName = "db.filter." + address.name
        filter.maximumRecents = 8
        run.keyEquivalent = "\r"
        run.keyEquivalentModifierMask = .command
        for button in [run, explain] {   // not stretched over the bar once the filter hides
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        let bar = Bar.content(
            [heading, part], [filter, run, explain, addRow, reload, copyAs, showInspector], stretching: filter)
        sqlText.font = .uiMono(11)
        sqlText.textColor = .secondaryLabelColor
        sqlText.maximumNumberOfLines = 3
        sqlText.lineBreakMode = .byTruncatingTail
        let sqlBox = NSStackView(views: [sqlText])
        sqlBox.edgeInsets = NSEdgeInsets(top: 6, left: Metrics.inset, bottom: 6, right: Metrics.inset)
        buildEditor()

        status.font = .uiDigits(11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        save.bezelStyle = .push
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        for button in [discard, ask, showSQL] { button.bezelStyle = .accessoryBarAction }
        let foot = Bar.foot([previous, next, status], [ask, showSQL, discard, save])
        grid.onChange = { [weak self] in self?.footChanged() }
        grid.onSort = { [weak self] _ in self?.sorted() }
        grid.onFilter = { [weak self] condition in self?.filterBy(condition) }
        inspector.onClose = { [weak self] in self?.toggleInspector() }
        grid.table.onSpace = { [weak self] in
            if self?.mode.table != nil || self?.mode.isRun == true { self?.toggleInspector() }
        }
        grid.table.onDelete = { [weak self] in
            if self?.grid.editable == true { self?.grid.deleteSelected() } else { NSSound.beep() }
        }
        inspector.onFollow = { [weak self] table, column, value in self?.follow(table, column, value) }
        inspector.view.isHidden = true

        buildAskBar()
        let rows = NSStackView(views: [grid.scroll, inspector.view])
        rows.spacing = 0
        rows.alignment = .height
        grid.scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let right = NSStackView(views: [askBar, bar, sqlBox, editor.view, rows, foot])
        right.orientation = .vertical
        right.spacing = 0
        right.detachesHiddenViews = true
        for v in [askBar, bar, sqlBox, editor.view, rows, foot] {
            v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        rows.setContentHuggingPriority(.defaultLow, for: .vertical)
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        left.setContentHuggingPriority(.required, for: .horizontal)
        let whole = NSStackView(views: [left, divider, right])
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

    /// What each mode shows: a table its part, filter, pages and row tools; a run its SQL; a query its editor.
    func arrange() {
        let table = mode.table != nil, data = table && part.selectedSegment == 0
        part.isHidden = !table
        filter.isHidden = !data
        for v in [addRow, previous, next] { v.isHidden = !data }
        addRow.isHidden = !data || !grid.editable
        reload.isHidden = mode.isRun
        showInspector.isHidden = mode == .query || (table && !data)
        copyAs.isHidden = false
        run.isHidden = mode != .query
        explain.isHidden = mode != .query
        sqlText.superview?.isHidden = !mode.isRun
        editor.view.isHidden = mode != .query
        if mode == .query || (table && !data) { inspector.view.isHidden = true }
        footChanged()
    }

    // MARK: The left list

    func loadTables() async {
        let (schema, error) = await app.tryCall(
            DatabaseSchemaRead(worktreeId: address.worktree, database: address.name))
        guard let schema else {
            empty.showError(String(localized: "Can't read \(address.name)"), text: error)
            return
        }
        tables = schema.tables
        listChanged()
        let named = address.table.flatMap { name in tables.first { $0.name == name } }
        if mode == .query, address.run == nil, !chosen, let first = named ?? tables.first {
            if let row = items.firstIndex(where: { if case .table(let t) = $0 { t.name == first.name } else { false } })
            {
                tableList.selectRowIndexes([row], byExtendingSelection: false)
            }
            mode = .table(first.name)
            await showTable(first.name)
        }
    }

    /// Tables, then New Query and the latest runs of this database.
    func listChanged() {
        // An agent's runs and any change: the tab's own reads of a page aren't history.
        let runs = (app.latest(DatabasesEvent.self, address.worktree)?.runs ?? []).filter {
            $0.database == address.name && ($0.session != nil || $0.changed != nil)
        }
        items =
            [.section(String(localized: "Tables"))] + tables.map(Item.table)
            + [.section(String(localized: "Queries")), .newQuery] + runs.prefix(20).map(Item.run)
        tableList.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = items[row] { return false }
        return true
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = items[row] { return TextSize.of(Metrics.rowSection) }
        return TextSize.of(Metrics.row)
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .section(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .ui(11, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            return line([label, NSView()])
        case .table(let t):
            return line([symbol("tablecells"), text(t.name), NSView(), digits(t.rows.map { $0.formatted() } ?? "")])
        case .newQuery:
            return line([
                symbol("chevron.left.forwardslash.chevron.right"), text(String(localized: "New Query")), NSView()
            ])
        case .run(let run):
            let who = run.session.flatMap(app.session)
            let icon = NSImageView(image: who.flatMap { app.catalog.icon($0.agent, size: 12) } ?? .symbol("person"))
            icon.contentTintColor = .secondaryLabelColor
            let sql = text(run.sql.split(whereSeparator: \.isNewline).joined(separator: " "), mono: true)
            sql.toolTip = run.sql
            return line([icon, sql, NSView(), digits(shortAgo(run.at))])
        }
    }

    private func line(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return stack
    }
    private func symbol(_ name: String) -> NSImageView {
        let icon = NSImageView(image: .symbol(name))
        icon.symbolConfiguration = .chrome(Metrics.iconSmall)
        icon.contentTintColor = .secondaryLabelColor
        return icon
    }
    private func text(_ s: String, mono: Bool = false) -> NSTextField {
        let name = NSTextField(labelWithString: s)
        name.font = mono ? .uiMono(11) : .ui(12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return name
    }
    private func digits(_ s: String) -> NSTextField {
        let count = NSTextField(labelWithString: s)
        count.font = .uiDigits(11)
        count.textColor = .tertiaryLabelColor
        return count
    }

    /// A table shows its rows, New Query the editor, a run its rows; ⌥ on a run puts its SQL in the editor.
    @objc private func listPicked() {
        guard items.indices.contains(tableList.clickedRow) else { return }
        switch items[tableList.clickedRow] {
        case .section: return
        case .table(let t): Task { await leave(to: .table(t.name)) }
        case .newQuery: Task { await leave(to: .query) }
        case .run(let run):
            if NSEvent.modifierFlags.contains(.option) {
                editor.textView.string = run.sql
                Task { await leave(to: .query) }
            } else {
                Task { await leave(to: .run(run.id)) }
            }
        }
    }

    /// Away from edits only once they're saved or dropped.
    func leave(to next: Mode) async {
        if isEdited, await !close() { return }
        chosen = true
        mode = next
        filter.stringValue = ""
        grid.order = nil
        page = 0
        part.selectedSegment = 0
        switch next {
        case .table(let name): await showTable(name)
        case .run(let id): await showRun(id)
        case .query: startedQuery()
        }
    }

    // MARK: Runs

    var database: DatabaseInfo? {
        let event = app.latest(DatabasesEvent.self, address.worktree)
        return (event?.databases ?? []).first { $0.name == address.name }
            ?? (event?.library ?? []).first { $0.name == address.name }
    }
    var engine: DatabaseInfo.Engine { database?.engine ?? .sqlite }

    func record(_ id: String) -> DatabaseRun? {
        app.latest(DatabasesEvent.self, address.worktree)?.runs.first { $0.id == id }
    }

    func showRun(_ id: String) async {
        arrange()
        let record = record(id)
        let who = record?.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "You")
        heading.stringValue = [who, record.map { shortAgo($0.at) }].compactMap { $0 }.joined(separator: " · ")
        sqlText.stringValue = record?.sql ?? ""
        let result = await app.quiet(DatabaseResultRead(worktreeId: address.worktree, id: id)) ?? nil
        grid.editable = false
        grid.source = nil
        grid.show(columns: result?.columns ?? [], rows: result?.rows ?? [])
        if let error = record?.error, record?.state != .asks {
            empty.showError(Self.stateTitle(record?.state ?? .failed), text: error)
        } else if result == nil {
            empty.show(
                String(localized: "Not Kept"), symbol: "clock",
                text: String(localized: "Kelp keeps the rows of the latest runs only."))
        } else if result?.columns.isEmpty == true, let changed = record?.changed, record?.state == .done {
            empty.show(String(localized: "\(changed) Rows Changed"), symbol: "checkmark.circle")
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

    /// The runs of this database changed: the bar follows the one that asks, a run shown takes its new state, the
    /// list its latest runs.
    private func runsChanged() {
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs.filter { $0.database == address.name } ?? []
        let was = asking
        asking = runs.first { $0.state == .asks }
        askBar.isHidden = asking == nil
        if let asking {
            let who =
                asking.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "An agent")
            askText.stringValue =
                asking.changed.map { String(localized: "\(who) wants to change \($0) rows in \(address.name)") }
                ?? String(localized: "\(who) wants to change \(address.name)")
            askText.toolTip = asking.sql
        }
        if case .run(let id) = mode, was?.id == id, asking?.id != id { Task { await showRun(id) } }
        listChanged()
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

    /// The user's statement, as theirs: a change runs without a question. Its error shows where the rows would.
    func query(_ sql: String, limit: Int = ResultGrid.shown) async -> QueryResult? {
        let (result, error) = await app.tryCall(
            DatabaseQuery(worktreeId: address.worktree, database: address.name, sql: sql, limit: limit))
        if let error {
            grid.show(columns: [], rows: [])
            empty.showError(String(localized: "\(address.name) said no"), text: error)
            status.stringValue = ""
        }
        return result
    }

    // MARK: The foot and the agent

    func footChanged() {
        let edits = grid.edits.count
        save.title = String(localized: "Save \(edits) Changes")
        for v in [save, discard, showSQL] { v.isHidden = edits == 0 }
        let picked = grid.selectedRows.count, agent = agentToAsk
        ask.isHidden = picked == 0 || agent == nil || edits > 0
        if let agent { ask.title = String(localized: "Ask \(app.catalog.name(agent.agent)) About \(picked) Rows") }
        if !inspector.view.isHidden { inspect() }
    }

    /// The chat a run came from, else the one in focus, else the workspace's last agent still there.
    private var agentToAsk: Session? {
        if case .run(let id) = mode, let sid = record(id)?.session, let s = app.session(sid), s.status != .exited {
            return s
        }
        return Self.agent(app, worktree: address.worktree)
    }

    /// The agent in focus in the workspace, else its last one still there: who "Ask Agent" hands things to.
    static func agent(_ app: AppModel, worktree: String) -> Session? {
        if let sid = app.workbench.focusedSession, let s = app.session(sid), s.worktreeId == worktree, s.agent != nil {
            return s
        }
        return app.sessions.last { $0.worktreeId == worktree && $0.agent != nil && $0.status != .exited }
    }

    @objc private func askAgent() {
        guard let agent = agentToAsk else { return }
        let picked = Array(grid.selectedRows.prefix(50))
        let source = mode.table.map { String(localized: "the table \($0)") } ?? sqlText.stringValue
        let text = "Rows of \(address.name) (\(source)):\n" + grid.text(picked) + "\n"
        Task {
            guard await app.call(SessionSend(id: agent.id, text: text, enter: false)) != nil else { return }
            app.workbench.focus(session: agent.id)
        }
    }
}
