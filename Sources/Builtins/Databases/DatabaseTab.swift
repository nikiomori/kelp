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
    var title: String { Self.title(address) }
    static func title(_ address: DatabaseURI) -> String {
        address.table.map { "\($0) · \(address.name)" } ?? address.name
    }
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

    func focus() {
        guard mode != .query else { return editor.focus() }
        view.window?.makeFirstResponder(grid.table)
    }

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
        sqlText.font = .uiMono(TextSize.caption)
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
        capsule.font = .ui(TextSize.caption, weight: .medium)
        capsule.textColor = .secondaryLabelColor
        capsule.lineBreakMode = .byTruncatingMiddle
        capsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        capsuleBox.spacing = Metrics.gap
        capsuleBox.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let capsuleButton = CapsuleControl { [weak self] in self?.capsuleClicked() }
        capsuleButton.pin(capsuleBox)
        capsuleBox.toolTip = String(localized: "Its menu: environment, what agents may do, address")
        for button in [run, explain] { button.setContentHuggingPriority(.required, for: .horizontal) }
        filterToggle.keyEquivalent = "f"
        filterToggle.keyEquivalentModifierMask = [.command, .shift]
        run.keyEquivalent = "\r"
        run.keyEquivalentModifierMask = .command
        return Bar.content(
            [capsuleButton], [run, explain, reload, filterToggle, copyAs, detailsToggle], stretching: capsuleButton)
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
        status.font = .uiDigits(TextSize.caption)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changes.font = .ui(TextSize.caption, weight: .medium)
        changes.textColor = .textOrange
        busy.style = .spinning
        busy.controlSize = .small
        busy.isDisplayedWhenStopped = false
        return Bar.foot(
            [part, addRow, busy, status],
            [changes, showSQL, discard, save, ask, saveQuery, columnsButton, previous, next])
    }

    private func buildAskBar() {
        askText.font = .ui(TextSize.row, weight: .medium)
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
        askBar.layer?.backgroundColor = NSColor.fillTint(.systemOrange).cgColor
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
            guard let self, let table = tables.first(where: { $0.name == name }) else { return }
            copyText(definition(table))
        }
        details.onEdit = { [weak self] column, value in self?.editFromDetails(column, value) }
        details.onFollow = { [weak self] table, column, value in self?.follow(table, column, value) }
        details.onRun = { [weak self] run in Task { await self?.leave(to: .run(run.id)) } }
        details.onAsk = { [weak self] in if let table = self?.mode.table { self?.askAbout(table) } }
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
            case .table(let table): table
            case .run: String(localized: "an agent’s run")
            case .query: String(localized: "Query")
            }
        let parts = [
            version ?? db.map { $0.engine.displayName },
            db?.database ?? db?.path.map { ($0 as NSString).lastPathComponent } ?? address.name,
            db?.ssh.map { String(localized: "via \($0)") }, place
        ]
        capsule.stringValue = parts.compactMap { $0 }.joined(separator: " · ")
        // The environment as the databases list shows it, a tag; the rest quiet. A whole red line read as an error.
        capsuleBox.setViews([db.flatMap(DatabaseLook.stageChip), capsule, NSView()].compactMap { $0 }, in: .leading)
    }

    private func askVersion() async {
        guard let db = database else { return }
        let check = await app.quiet(
            DatabaseCheck(worktreeId: address.worktree, database: db, versionOnly: true), timeout: 30)
        version = check?.version
        capsuleChanged()
    }

    private func capsuleClicked() {
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

}

/// The capsule as a control: under the pointer it fills, a click springs it and opens its menu.
@MainActor
private final class CapsuleControl: PointerControl {
    private let run: () -> Void
    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        layer?.cornerRadius = Metrics.radiusSM
    }
    required init?(coder: NSCoder) { fatalError() }
    override func clicked() { run() }
}
