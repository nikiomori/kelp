import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// "db:<workspace>/<name>[?run=<id>|?table=<name>]", laid out as TablePlus and TablePro lay a database out: on the
/// left its items, saved queries and history (`DatabaseSidebar`); on top its environment's tag (PROD in red) and,
/// quieter, where you are, and the filter's rows under it (⇧⌘F); in the middle a table's rows, a run's, or a query
/// of the user's own; at the foot everything about the table shown (Data / Structure, + Row, how many, the changes,
/// Columns, pages); on the right its details (`DatabaseDetails`). While an agent asks to change this database, a bar
/// over it all says who and how much, with Deny / Allow.
@MainActor
final class DatabaseTab: NSObject, KelpKit.TabContent {
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

    let uri: String
    let view = NSView()
    var title: String { address.table.map { "\($0) · \(address.name)" } ?? address.name }
    var icon: NSImage? { .symbol(DatabaseLook.symbol) }
    var isEdited: Bool { !grid.edits.isEmpty }

    let app: AppModel
    let address: DatabaseURI
    var mode: Mode
    var schema = DatabaseSchema(tables: [])
    var tables: [DatabaseSchema.Table] { schema.tables }
    let sidebar: DatabaseSidebar
    let grid = ResultGrid()
    let details = DatabaseDetails()
    let filters = DatabaseFilters()
    let empty = EmptyStateView()
    /// Over the whole tab until the database is open: connecting, or why it isn't and what to do.
    let gate = EmptyStateView()
    let loading = DatabaseLoading()
    /// Turning in the foot while a page is read (past half a second).
    let busy = NSProgressIndicator()
    let whole = NSSplitView()
    let capsule = NSTextField(labelWithString: "")
    let capsuleBox = NSStackView()
    let part = NSSegmentedControl(
        labels: [String(localized: "Data"), String(localized: "Structure")], trackingMode: .selectOne, target: nil,
        action: nil)
    let sqlText = NSTextField(wrappingLabelWithString: "")
    lazy var editor = CodeEditor(text: "", url: URL(fileURLWithPath: "/query.sql"))
    let status = NSTextField(labelWithString: "")
    let changes = NSTextField(labelWithString: "")
    let askBar = NSStackView()
    let askText = NSTextField(labelWithString: "")
    var asking: DatabaseRun?
    /// The server's version, once asked (for the capsule).
    var version: String?
    /// The first event came: what waited on it was asked for.
    var started = false
    /// The user picked what to show: the first table, shown once the list is read, no longer takes over.
    var chosen = false
    /// The page of a table's rows shown, and how many a page holds.
    var page = 0
    static let pageSize = 200
    /// Rows the table has with the filter on, when it was counted.
    var counted: Int?
    /// While rows are read: said only past half a second, so a quick read doesn't flicker.
    var reading: Task<Void, Never>?
    lazy var watched = Watched(.databases, in: app)
    lazy var run = NSButton(title: String(localized: "Run"), target: self, action: #selector(runQuery))
    lazy var explain = NSButton(title: String(localized: "Explain"), target: self, action: #selector(explainQuery))
    lazy var saveQuery = NSButton(title: String(localized: "Save Query…"), target: self, action: #selector(keepQuery))
    lazy var save = NSButton(title: String(localized: "Save"), target: self, action: #selector(saveEdits))
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
    lazy var addRow = ClosureButton(title: String(localized: "Row")) { [weak self] in self?.grid.addRow() }
    lazy var columnsButton = ClosureButton(title: String(localized: "Columns")) { [weak self] in self?.columnsMenu() }
    lazy var reload = IconButton(.symbol("arrow.clockwise"), tip: String(localized: "Read Again")) { [weak self] in
        self?.refresh()
    }
    lazy var filterToggle = IconButton(
        .symbol("line.3.horizontal.decrease.circle"), tip: String(localized: "Filters (⇧⌘F)")
    ) { [weak self] in self?.toggleFilters() }
    lazy var detailsToggle = IconButton(.symbol("sidebar.right"), tip: String(localized: "Details")) { [weak self] in
        guard let self else { return }
        details.view.isHidden.toggle()
        detailsClosed = details.view.isHidden
    }
    /// The user closed the details: picking a row no longer opens them.
    var detailsClosed = false

    lazy var copyAs = IconButton(.symbol("square.and.arrow.up"), tip: String(localized: "Copy or Export Rows")) {
        [weak self] in self?.copyMenu()
    }

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        address = DatabaseURI(uri) ?? DatabaseURI(worktree: "", name: "")
        mode = address.run.map(Mode.run) ?? .query
        sidebar = DatabaseSidebar(app: app)
        super.init()
        build()
        wire()
        watched.key = address.worktree
        track(owner: self) { [app, address] in
            app.latest(DatabasesEvent.self, address.worktree)?.runs.filter { $0.database == address.name }
        } changed: { [weak self] _ in
            self?.runsChanged()
        }
        track(owner: self) { [app] in
            app.settings[SettingKeys.databaseDensity]
        } changed: { [weak self] density in
            self?.grid.density = density
            self?.grid.table.reloadData()
        }
        // The workspace's databases come with its first event: then the capsule's version and the saved queries.
        track(owner: self) { [app, address] in
            app.latest(DatabasesEvent.self, address.worktree) != nil
        } changed: { [weak self] known in
            guard known, let self, !self.started else { return }
            self.started = true
            Task { await self.loadQueries() }
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
        let top = capsuleBar()
        filters.view.setContentHuggingPriority(.required, for: .vertical)
        sqlText.font = .uiMono(11)
        sqlText.textColor = .secondaryLabelColor
        sqlText.maximumNumberOfLines = 3
        sqlText.lineBreakMode = .byTruncatingTail
        let sqlBox = NSStackView(views: [sqlText])
        sqlBox.edgeInsets = NSEdgeInsets(top: 6, left: Metrics.inset, bottom: 6, right: Metrics.inset)
        buildEditor()
        buildAskBar()
        let foot = footBar()
        let center = NSStackView(views: [askBar, top, filters.view, sqlBox, editor.view, grid.scroll, foot])
        center.orientation = .vertical
        center.spacing = 0
        center.detachesHiddenViews = true
        for v in [askBar, top, filters.view, sqlBox, editor.view, grid.scroll, foot] {
            v.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        }
        grid.scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The list and the details keep their width as the window changes; the rows take the rest. The list's width is
        // the user's to drag, kept per Mac. The details stay closed until a row is picked.
        whole.isVertical = true
        whole.dividerStyle = .thin
        for pane in [sidebar.view, center, details.view] { whole.addArrangedSubview(pane) }
        whole.setHoldingPriority(.init(260), forSubviewAt: 0)
        whole.setHoldingPriority(.init(200), forSubviewAt: 1)
        whole.setHoldingPriority(.init(260), forSubviewAt: 2)
        // The split starts from its panes' frames: the list 280 wide until the user drags it (then kept, per Mac).
        sidebar.view.setFrameSize(NSSize(width: 280, height: 400))
        center.setFrameSize(NSSize(width: 800, height: 400))
        details.view.setFrameSize(NSSize(width: DatabaseDetails.width, height: 400))
        whole.autosaveName = "DatabaseTab"
        details.view.isHidden = true
        center.setContentHuggingPriority(.init(1), for: .horizontal)
        view.pin(whole)
        gate.place(in: view)
        view.pin(loading)
        empty.place(in: grid.scroll)
        arrange()
    }

    /// Where you are: the environment's tag, then "PostgreSQL 16.4 · AGR_GIS · public.orders"; a click, its menu.
    private func capsuleBar() -> NSView {
        capsule.font = .ui(11.5, weight: .medium)
        capsule.textColor = .secondaryLabelColor
        capsule.lineBreakMode = .byTruncatingMiddle
        capsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        capsuleBox.spacing = Metrics.gap
        capsuleBox.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let menuClick = NSClickGestureRecognizer(target: self, action: #selector(capsuleClicked))
        capsuleBox.addGestureRecognizer(menuClick)
        capsuleBox.toolTip = String(localized: "Its menu: environment, what agents may do, address")
        for button in [run, explain] { button.setContentHuggingPriority(.required, for: .horizontal) }
        filterToggle.keyEquivalent = "f"
        filterToggle.keyEquivalentModifierMask = [.command, .shift]
        run.keyEquivalent = "\r"
        run.keyEquivalentModifierMask = .command
        return Bar.content(
            [capsuleBox], [run, explain, reload, filterToggle, copyAs, detailsToggle], stretching: capsuleBox)
    }

    private func footBar() -> NSView {
        part.selectedSegment = 0
        part.controlSize = .small
        part.target = self
        part.action = #selector(partChanged)
        part.setContentHuggingPriority(.required, for: .horizontal)
        addRow.image = .symbol("plus")
        addRow.imagePosition = .imageLeading
        for button in [addRow, columnsButton, discard, showSQL, ask, saveQuery] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
        }
        save.bezelStyle = .push
        save.controlSize = .small
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        status.font = .uiDigits(11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changes.font = .ui(11, weight: .medium)
        changes.textColor = .textOrange
        busy.style = .spinning
        busy.controlSize = .small
        busy.isDisplayedWhenStopped = false
        return Bar.foot(
            [part, addRow, busy, status],
            [changes, showSQL, discard, save, ask, saveQuery, columnsButton, previous, next])
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

    /// The parts that talk to each other.
    private func wire() {
        grid.density = app.settings[SettingKeys.databaseDensity]
        grid.onChange = { [weak self] in self?.footChanged() }
        grid.onSort = { [weak self] in self?.sorted() }
        grid.onFilter = { [weak self] column, op, value in self?.filters.add(column: column, op: op, value: value) }
        grid.onFollow = { [weak self] column, value in self?.followKey(column, value) }
        grid.table.onSpace = { [weak self] in
            self?.detailsClosed = false
            self?.details.view.isHidden = false
            self?.details.show(.row)
        }
        grid.table.onDelete = { [weak self] in
            if self?.grid.editable == true { self?.grid.deleteSelected() } else { NSSound.beep() }
        }
        filters.onApply = { [weak self] _ in self?.filtered() }
        sidebar.onTable = { [weak self] name, pin in self?.openTable(name, pin: pin) }
        sidebar.onNewQuery = { [weak self] in Task { await self?.leave(to: .query) } }
        sidebar.onSaved = { [weak self] q in self?.openSaved(q) }
        sidebar.onForget = { [weak self] q in self?.forget(q) }
        sidebar.onRun = { [weak self] run, toEditor in self?.openRun(run, toEditor: toEditor) }
        sidebar.onAsk = { [weak self] table in self?.askAbout(table) }
        sidebar.onCopyCreate = { [weak self] name in
            guard let self, let t = tables.first(where: { $0.name == name }) else { return }
            copyText(definition(t))
        }
        details.onEdit = { [weak self] column, value in self?.editFromDetails(column, value) }
        details.onFollow = { [weak self] table, column, value in self?.follow(table, column, value) }
        details.onRun = { [weak self] run in Task { await self?.leave(to: .run(run.id)) } }
        details.onAsk = { [weak self] in if let t = self?.mode.table { self?.askAbout(t) } }
    }

    /// What each mode shows: a table its part, filters and the row tools; a run its SQL; a query its editor.
    func arrange() {
        let table = mode.table != nil, data = table && part.selectedSegment == 0
        part.isHidden = !table
        filterToggle.isHidden = !data
        if !data { filters.view.isHidden = true }
        for v in [previous, next, columnsButton] as [NSView] { v.isHidden = !data }
        addRow.isHidden = !data || !grid.editable
        reload.isHidden = mode.isRun
        run.isHidden = mode != .query
        explain.isHidden = mode != .query
        saveQuery.isHidden = mode != .query
        sqlText.superview?.isHidden = !mode.isRun
        editor.view.isHidden = mode != .query
        capsuleChanged()
        footChanged()
    }

    // MARK: The capsule

    var database: DatabaseInfo? {
        let event = app.latest(DatabasesEvent.self, address.worktree)
        return (event?.databases ?? []).first { $0.name == address.name }
            ?? (event?.library ?? []).first { $0.name == address.name }
    }
    var engine: DatabaseInfo.Engine { database?.engine ?? .sqlite }

    func capsuleChanged() {
        let db = database
        let place: String? =
            switch mode {
            case .table(let t): t
            case .run: String(localized: "an agent’s run")
            case .query: String(localized: "Query")
            }
        let parts = [
            version ?? db.map { DatabaseLook.engine($0.engine) },
            db?.database ?? db?.path.map { ($0 as NSString).lastPathComponent } ?? address.name,
            db?.ssh.map { String(localized: "via \($0)") }, place
        ]
        capsule.stringValue = parts.compactMap { $0 }.joined(separator: " · ")
        // The environment as the databases list shows it, a tag; the rest quiet. A whole red line read as an error.
        capsuleBox.setViews([db.flatMap(DatabaseLook.stageChip), capsule, NSView()].compactMap { $0 }, in: .leading)
    }

    private func askVersion() async {
        guard let db = database else { return }
        let check = await app.quiet(DatabaseCheck(worktreeId: address.worktree, database: db), timeout: 30)
        version = check?.version
        capsuleChanged()
    }

    @objc private func capsuleClicked() {
        guard let db = database else { return }
        let menu = NSMenu()
        let library =
            app.latest(DatabasesEvent.self, address.worktree)?.library?.contains { $0.name == db.name } ?? false
        DatabaseMenu.fill(menu, db, app: app, worktreeId: address.worktree, library: library)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: capsuleBox.bounds.height + 4), in: capsuleBox)
    }

    // MARK: Loading

    func loadTables() async {
        let first = schema.tables.isEmpty && version == nil
        if first { connecting() }
        let (read, error) = await app.tryCall(
            DatabaseSchemaRead(worktreeId: address.worktree, database: address.name))
        reading?.cancel()
        loading.hide()
        guard let read else {
            if first { return failed(error ?? String(localized: "It doesn’t answer.")) }
            empty.showError(String(localized: "Can't read \(address.name)"), text: error)
            return
        }
        whole.isHidden = false
        gate.show(nil)
        if version == nil { Task { await askVersion() } }   // after: one connection asks macOS for a password, not two
        schema = read
        sidebar.schema = read
        let named = address.table.flatMap { name in tables.first { $0.name == name } }
        if mode == .query, address.run == nil, !chosen,
            let first = named ?? tables.first(where: { $0.kind != "view" })
        {
            mode = .table(first.name)
            await showTable(first.name)
        }
    }

    // MARK: Runs

    func record(_ id: String) -> DatabaseRun? {
        app.latest(DatabasesEvent.self, address.worktree)?.runs.first { $0.id == id }
    }

    func showRun(_ id: String) async {
        arrange()
        sidebar.current = nil
        let record = record(id)
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
            empty.show(Self.rows(changed, changed: true).capitalizedFirst, symbol: "checkmark.circle")
        } else {
            empty.show(
                result?.rows.isEmpty == true && result?.columns.isEmpty == false ? String(localized: "No Rows") : nil)
        }
        let who = record?.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "You")
        status.stringValue = [who, record.map { shortAgo($0.at) }, record.map(Self.summary)].compactMap { $0 }
            .joined(separator: " · ")
        footChanged()
    }

    static func stateTitle(_ state: DatabaseRun.State) -> String {
        switch state {
        case .denied: String(localized: "Denied")
        case .refused: String(localized: "Refused")
        default: String(localized: "Failed")
        }
    }

    /// "1 row", "200 rows", "3 rows changed": the plural right.
    static func rows(_ n: Int, changed: Bool = false) -> String {
        let count = n == 1 ? String(localized: "1 row") : String(localized: "\(n.formatted()) rows")
        return changed ? count + " " + String(localized: "changed") : count
    }

    /// "84 ms", "1.5 s": how long a read took.
    nonisolated static func took(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func summary(_ run: DatabaseRun) -> String {
        switch run.state {
        case .asks:
            return run.changed.map { rows($0) + " " + String(localized: "would change: shown as they would be") }
                ?? String(localized: "Waits for your answer")
        case .done:
            let what = run.changed.map { rows($0, changed: true) } ?? rows(run.rows ?? 0)
            return [what, run.ms.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · ")
        default: return run.error ?? ""
        }
    }

    /// The runs of this database changed: the bar follows the one that asks, a run shown takes its new state, the
    /// list and the details their latest.
    private func runsChanged() {
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs.filter { $0.database == address.name } ?? []
        let was = asking
        asking = runs.first { $0.state == .asks }
        askBar.isHidden = asking == nil
        if let asking {
            let who =
                asking.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "An agent")
            askText.stringValue =
                asking.changed.map { String(localized: "\(who) wants to change \(Self.rows($0)) in \(address.name)") }
                ?? String(localized: "\(who) wants to change \(address.name)")
            askText.toolTip = asking.sql
        }
        if case .run(let id) = mode, was?.id == id, asking?.id != id { Task { await showRun(id) } }
        // An agent's runs and any change: the tab's own reads of a page aren't history.
        sidebar.runs = runs.filter { $0.session != nil || $0.changed != nil }
        detailsChanged()
        capsuleChanged()
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

    private func openRun(_ run: DatabaseRun, toEditor: Bool) {
        guard toEditor else {
            Task { await leave(to: .run(run.id)) }
            return
        }
        editor.textView.string = run.sql
        Task { await leave(to: .query) }
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

    /// Away from edits only once they're saved or dropped.
    func leave(to next: Mode) async {
        if isEdited, await !close() { return }
        chosen = true
        mode = next
        grid.orders = []
        page = 0
        part.selectedSegment = 0
        if next.table == nil { filters.clear() }
        switch next {
        case .table(let name): await showTable(name)
        case .run(let id): await showRun(id)
        case .query: startedQuery()
        }
    }

    /// A table in this tab (it replaces the one shown), or in a tab of its own.
    private func openTable(_ name: String, pin: Bool) {
        if pin {
            app.workbench.open(DatabaseURI(worktree: address.worktree, name: address.name, table: name).uri)
        } else {
            filters.clear()
            Task { await leave(to: .table(name)) }
        }
    }

    // MARK: The foot and the agent

    func footChanged() {
        let edits = grid.edits.count
        changes.stringValue =
            edits == 0 ? "" : edits == 1 ? String(localized: "1 change") : String(localized: "\(edits) changes")
        for v in [save, discard, showSQL] { v.isHidden = edits == 0 }
        let picked = grid.selectedRows.count, agent = agentToAsk
        ask.isHidden = picked == 0 || agent == nil || edits > 0 || mode == .query
        if let agent {   // short: the count is the selection on screen, and in the tooltip
            let name = app.catalog.name(agent.agent)
            ask.title = String(localized: "Ask \(name)")
            ask.image = app.catalog.icon(agent.agent, size: 14)
            ask.imagePosition = .imageLeading
            ask.toolTip = String(localized: "Ask \(name) about \(Self.rows(picked))")
        }
        detailsChanged()
    }

    /// The chat a run came from, else the one in focus, else the workspace's last agent still there.
    var agentToAsk: Session? {
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
        send("Rows of \(address.name) (\(source)):\n" + grid.text(picked) + "\n", to: agent)
    }

    private func askAbout(_ table: String) {
        guard let agent = agentToAsk else { return NSSound.beep() }
        send("About " + DatabasesPanel.mention(table, in: address.name) + ": ", to: agent)
    }

    private func send(_ text: String, to agent: Session) {
        Task {
            guard await app.call(SessionSend(id: agent.id, text: text, enter: false)) != nil else { return }
            app.workbench.focus(session: agent.id)
        }
    }
}
