import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// The tab for "db:<workspace>/<name>[?run=<id>|?table=<name>]", laid out the way TablePlus and TablePro lay out a
/// database:
/// - on the left, the database's items, saved queries and history (`DatabaseSidebar`);
/// - on top, the environment's tag (Production in red) and, more quietly, where you are, with the filter's rows under
/// it (Filters: no key of its own, ⇧⌘F is Find in Project everywhere; one can be set in Settings › Keyboard);
/// - in the middle, a table's rows, a run's rows, or a query of the user's own;
/// - at the foot, everything about the table shown (Data / Structure, Add Row, the row count, the changes, Columns,
/// pages);
/// - on the right, the details (`DatabaseDetails`).
/// While an agent asks to change this database, a bar above everything says which agent and how much, with Deny and
/// Allow.
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
    /// What the tab strip calls the tab. It follows what's shown (`DatabaseTabName`).
    let name: DatabaseTabName
    var title: String { name.title }
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
    /// Covers the whole tab until the database is open, saying it is connecting, or why it isn't and what to do.
    let gate = EmptyStateView()
    let loading = LoadingView()
    /// Over the empty grid while a database elsewhere reads its first rows.
    let rowsWait = LoadingView()
    /// Over rows that are kept when reading them again failed: why, and Try Again.
    lazy var failureBar = FailureBar { [weak self] in self?.refresh() }
    /// Spins in the foot while a page is read, once the read takes past a second.
    let busy = NSProgressIndicator()
    let whole = NSSplitView()
    let capsule = NSTextField(labelWithString: "")
    let capsuleBox = NSStackView()
    let capsuleButton = PointerControl(frame: .zero)
    let part = CapsuleSegments(
        labels: [String(localized: "Data"), String(localized: "Structure")],
        name: String(localized: "Show"))
    let sqlText = NSTextField(wrappingLabelWithString: "")
    lazy var editor = CodeEditor(text: "", url: URL(fileURLWithPath: "/query.sql"))
    /// Keeps the query typed in the editor for the database once typing pauses (`keepDraft`).
    let draft = Debounce()
    let status = NSTextField(labelWithString: "")
    let changes = NSTextField(labelWithString: "")
    let askBar = FillStack()
    let askText = NSTextField(labelWithString: "")
    var asking: DatabaseRun?
    /// The server's version once it has been asked, for the capsule.
    var version: String?
    /// True once the first event came and what waited on it was asked for.
    var started = false
    /// True once the user picked what to show, so the first table, shown once the list is read, no longer takes over.
    var chosen = false
    /// The page of a table's rows that is shown, and how many rows a page holds.
    var page = 0
    static let pageSize = 200
    /// How many rows the table has with the filter on, once they were counted.
    var counted: Int?
    /// The read in progress. It is shown only past a second, so a quick read doesn't flicker.
    var reading: Task<Void, Never>?
    lazy var watched = Watched(.databases, in: app)
    lazy var run = NSButton(title: String(localized: "Run"), target: self, action: #selector(runQuery))
    /// Explain is a bar's worded button, the grey plate, beside Run, the one main action in the system's accent.
    lazy var explain = TextButton(String(localized: "Explain"), target: self, action: #selector(explainQuery))
    lazy var saveQuery = NSButton(title: String(localized: "Save Query…"), target: self, action: #selector(keepQuery))
    lazy var save = NSButton(title: String(localized: "Save"), target: self, action: #selector(saveEdits))
    lazy var showSQL = NSButton(title: String(localized: "Show SQL"), target: self, action: #selector(showEdits))
    lazy var discard = NSButton(
        title: String(localized: "Discard…"), target: self, action: #selector(discardEdits))
    lazy var ask = NSButton(title: "", target: self, action: #selector(askAgent))
    lazy var previous = IconButton(.symbol("chevron.left"), tip: String(localized: "Previous Rows")) { [weak self] in
        self?.turn(-1)
    }
    lazy var next = IconButton(.symbol("chevron.right"), tip: String(localized: "Next Rows")) { [weak self] in
        self?.turn(1)
    }
    lazy var addRow = ClosureButton(title: String(localized: "Add Row")) { [weak self] in self?.grid.addRow() }
    lazy var columnsButton = ClosureButton(title: String(localized: "Columns")) { [weak self] in self?.columnsMenu() }
    lazy var reload = IconButton(.symbol("arrow.clockwise"), tip: String(localized: "Refresh")) { [weak self] in
        self?.refresh()
    }
    lazy var filterToggle = IconButton(
        .symbol("line.3.horizontal.decrease.circle"),
        tip: app.extensions.hint(String(localized: "Filters"), "databases.filters")
    ) { [weak self] in self?.toggleFilters() }
    lazy var detailsToggle = IconButton(.symbol("sidebar.right"), tip: String(localized: "Details")) { [weak self] in
        self?.toggleDetails()
    }
    /// True once the user closed the details, so picking a row no longer opens them.
    var detailsClosed = false

    lazy var copyAs = IconButton(.symbol("square.and.arrow.up"), tip: String(localized: "Copy or Export Rows")) {
        [weak self] in self?.copyMenu()
    }

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        address = DatabaseURI(uri) ?? DatabaseURI(worktree: "", name: "")
        mode = address.run.map(Mode.run) ?? .query
        name = DatabaseTabName(Self.title(address))
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
        // The workspace's databases come with its first event, and then the capsule's version and the saved queries
        // are asked for.
        track(owner: self) { [app, address] in
            app.latest(DatabasesEvent.self, address.worktree) != nil
        } changed: { [weak self] known in
            guard known, let self, !self.started else { return }
            self.started = true
            self.loadQueries()
        }
        Task { await loadTables() }
        if case .run(let id) = mode { Task { await showRun(id) } }
    }

    func focus() {
        guard mode != .query else { return editor.focus() }
        view.window?.makeFirstResponder(grid.table)
    }

    func close() async -> Bool {
        keepDraft()
        return isEdited ? await settleEdits() : true
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
        let rows = buildEditor()   // the query's editor over the rows
        buildAskBar()
        let foot = footBar()
        // One main action per bar is in the accent colour (macOS 26's primary tint, and the bezel colour before it).
        for button in [run, save] {
            if #available(macOS 26, *) {
                button.tintProminence = .primary
            } else {
                button.bezelColor = .controlAccentColor
            }
        }
        let center = NSStackView(views: [askBar, top, failureBar, filters.view, sqlBox, rows, foot])
        center.orientation = .vertical
        center.spacing = 0
        center.detachesHiddenViews = true
        for v in [askBar, top, failureBar, filters.view, sqlBox, rows, foot] {
            v.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        }
        rows.setContentHuggingPriority(.defaultLow, for: .vertical)
        // The list and the details keep their width as the window changes, and the rows take the rest. The user can
        // drag the list's width, which is kept per Mac. The details stay closed until a row is picked.
        whole.isVertical = true
        whole.dividerStyle = .thin
        for pane in [sidebar.view, center, details.view] { whole.addArrangedSubview(pane) }
        whole.setHoldingPriority(.init(260), forSubviewAt: 0)
        whole.setHoldingPriority(.init(200), forSubviewAt: 1)
        whole.setHoldingPriority(.init(260), forSubviewAt: 2)
        // The split starts from its panes' frames. The list is 280 wide until the user drags it, and then its width
        // is kept per Mac.
        sidebar.view.setFrameSize(NSSize(width: 280, height: 400))
        center.setFrameSize(NSSize(width: 800, height: 400))
        details.view.setFrameSize(NSSize(width: DatabaseDetails.width, height: 400))
        whole.autosaveName = "DatabaseTab"
        details.view.isHidden = true
        center.setContentHuggingPriority(.init(1), for: .horizontal)
        view.pin(whole)
        gate.place(in: view)
        loading.place(in: view)
        empty.place(in: grid.area)   // over the scroll view, not in it, where the rows' background would cover it
        rowsWait.place(in: grid.area)
        arrange()
    }

    /// Where you are: the environment's tag, then "PostgreSQL 16.4 · AGR_GIS · public.orders". A click opens the
    /// database's menu.
    private func capsuleBar() -> NSView {
        capsule.font = .ui(TextSize.caption, weight: .medium)
        capsule.textColor = .secondaryLabelColor
        capsule.lineBreakMode = .byTruncatingMiddle
        capsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        capsuleBox.spacing = Metrics.gap
        capsuleBox.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.iconButton)).isActive = true
        capsuleButton.layer?.cornerRadius = Metrics.radiusSM
        capsuleButton.onClick = { [weak self] in self?.capsuleClicked() }
        capsuleButton.pin(capsuleBox)
        capsuleButton.toolTip = String(localized: "Its menu: environment, what agents may do, address")
        capsuleButton.setAccessibilityElement(true)   // one button to VoiceOver, named in `capsuleChanged`
        capsuleButton.setAccessibilityRole(.button)
        for button in [run, explain] { button.setContentHuggingPriority(.required, for: .horizontal) }
        // The keys are the commands' (DatabasesBuiltin), as Settings › Keyboard has them.
        run.toolTip = app.extensions.hint(String(localized: "Run"), "databases.run")
        explain.toolTip = app.extensions.hint(String(localized: "Explain the Statement"), "databases.explain")
        save.toolTip = app.extensions.hint(String(localized: "Save Changes"), "databases.save")
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
        // Inside a page a worded button is the system's small bordered one, so it reads as a button before a hover.
        for button in [addRow, columnsButton, discard, showSQL, ask, saveQuery, save] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        status.font = .uiDigits(TextSize.caption)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changes.font = .uiDigits(TextSize.caption, weight: .medium)
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
        for button in [show, deny, allow] {
            button.bezelStyle = .push
            button.controlSize = .small
        }
        let mark = NSImageView(image: .symbol("exclamationmark.bubble"))
        mark.symbolConfiguration = .chrome()
        mark.contentTintColor = .textOrange
        for v in [mark, askText, NSView(), show, deny, allow] { askBar.addArrangedSubview(v) }
        askBar.spacing = Metrics.gapWide
        askBar.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        askBar.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.contentBar)).isActive = true
        askBar.fill = .fillTint(.systemOrange)   // read again on a light / dark change
        askBar.isHidden = true
    }

    /// Wires up the parts that talk to each other.
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
        sidebar.onUndo = { [weak self] run in self?.undo(run) }
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

    /// Shows what each mode needs: a table gets its part, filters and row tools; a run its SQL; a query its editor.
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
        // Until something is picked, the tab is named by its address, because a query isn't what the tab opens on.
        name.title = mode == .query && !chosen ? Self.title(address) : Self.title(address.name, showing: mode)
        capsuleChanged()
        footChanged()
    }

    // MARK: Loading

    func loadTables() async {
        let first = schema.tables.isEmpty && version == nil
        if first { connecting() }
        let (read, error) = await app.tryCall(
            DatabaseSchemaRead(worktreeId: address.worktree, database: address.name))
        reading?.cancel()
        await loading.settled()
        loading.show(nil)
        guard let read else {
            if first { return failed(error ?? String(localized: "It doesn’t answer.")) }
            failureBar.show(error ?? String(localized: "It doesn’t answer."))   // what shows stays, under the line
            return
        }
        failureBar.show(nil)
        whole.isHidden = false
        gate.show(nil)
        if version == nil { Task { await askVersion() } }   // after, so macOS asks for a password once, not twice
        schema = read
        sidebar.schema = read
        let named = address.table.flatMap { name in tables.first { $0.name == name } }
        if mode == .query, address.run == nil, !chosen,
            let first = named ?? tables.first(where: { $0.kind != "view" && $0.name != read.migrations?.table })
        {
            mode = .table(first.name)
            await showTable(first.name)
        }
    }

}
