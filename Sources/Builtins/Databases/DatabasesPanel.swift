import AppKit
import Core
import DesignKit
import KelpKit

/// The Databases panel, which lists connections like TablePlus' left column, most urgent first. At the top is an
/// agent's change that waits for the user, with Allow in the row. Then comes the project's card, where each database
/// shows its name, environment, "host : database", a dot that says whether it answers, and an icon for what agents
/// may do, with Use a Database… last. Then come All My Databases with a card per group, and what agents ran lately.
/// Over the list are a field that finds a database and the one +. A database opens its tab, where its tables are.
@MainActor
final class DatabasesPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    enum Row {
        case heading(Heading)
        case asks(DatabaseRun)
        case database(DatabaseInfo, library: Bool)
        /// A group of All My Databases (TablePlus' group, DBeaver's folder, or one made here), with its rows under it.
        case group(String, count: Int)
        case problem(DatabaseInfo, DatabaseHealth)
        /// The project's card: its own row, then its databases, then Use a Database… (`empty` when it uses none yet).
        case project(count: Int)
        case use(empty: Bool)
        case run(DatabaseRun)
    }
    enum Heading: Equatable {
        case asks, library(Int), activity(Int)
    }

    let app: AppModel
    let table = DropTable()
    private let search = NSSearchField()
    private let empty = EmptyStateView()
    private let loading = LoadingView(rows: true)
    /// The header every inspector panel has, 36 pt tall with its hairline.
    private var bar: Bar?
    var rows: [Row] = [] {
        didSet { cards = Self.cards(rows) }
    }
    /// Which part of a card each row is (the project's card or a group's card); nil for a row on its own.
    private var cards: [ListRowView.Card?] = []
    /// True while a drag of All My Databases is over the project's card, which lights up as the place they'd go.
    var dropOnProject = false {
        didSet {
            guard dropOnProject != oldValue else { return }
            if !dropOnProject { table.draggingDestinationFeedbackStyle = .regular }
            table.enumerateAvailableRowViews { view, row in (view as? ListRowView)?.card = card(row) }
        }
    }
    private lazy var watched = Watched(.databases, in: app)
    private var shown = false
    var workspace: String { app.workbench.workspaceId ?? "" }

    /// Which sections the user unfolded.
    var libraryOpen = true, activityOpen = true
    /// The groups of All My Databases that are folded, by name, kept on this Mac.
    var folded = Set(UserDefaults.standard.stringArray(forKey: "databases.foldedGroups") ?? []) {
        didSet { UserDefaults.standard.set(folded.sorted(), forKey: "databases.foldedGroups") }
    }
    /// The folded group a drag rests on, and since when. The group opens after a moment, as a folder does in Finder.
    var springGroup: (name: String, since: Date)?
    /// The colour under the pointer in a row's menu, shown on the row until the menu closes.
    var colorPreview: (name: String, group: Bool, color: ProjectColor?)? { didSet { table.reloadData() } }
    var health: [String: DatabaseHealth] = [:]
    /// The health dots of All My Databases, read once the section is open.
    private var libraryHealth: [String: DatabaseHealth] = [:], libraryCheckedFor: [String] = []
    private var libraryCount = Int.max   // the first read only counts the databases
    /// The databases (by address) the dots were last read for. The dots are read again when that list changes, not
    /// at each run.
    var checkedFor: [String] = []
    /// Shows the activity of one agent's session only; nil shows everyone's.
    var only: String?

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = table.plainList("d")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.allowsMultipleSelection = true   // to put several of All My Databases into a group, or into the project
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        // A .sqlite or .duckdb file dropped in opens Add Database with it. One of All My Databases dropped in goes
        // into a group, or is used here.
        table.registerForDraggedTypes([.fileURL, .kelpDatabase, .kelpDatabaseGroup])
        table.dragLeft = { [weak self] in self?.dropOnProject = false }
        search.placeholderString = String(localized: "Find a Database")
        search.delegate = self
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        // The + is the one way to add a database (or import some), shown whether the project has any or not.
        let add = IconButton(.symbol("plus"), tip: String(localized: "Add Database…")) { [weak self] in
            self?.addDatabase()
        }
        let bar = Bar.panel([search], [add], stretching: search)
        self.bar = bar
        let content = stacked(bar, scroll)
        empty.place(in: content)
        loading.place(in: content, under: bar)
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] _ in
            self?.checkedFor = []
            self?.watchShown()
        }
        track(owner: self) { [app] in
            app.latest(DatabasesEvent.self, app.workbench.workspaceId ?? "")
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [app] in
            app.workbench.focusedTab
        } changed: { [weak self] _ in
            self?.markOpen()
        }
    }
    /// The field starts where the rows' badges do, because the list's cells sit past the list's own edge.
    override func viewDidLayout() {
        super.viewDidLayout()
        alignSearch()
    }
    private func alignSearch() {
        guard !rows.isEmpty else { return }
        let left = Metrics.inset + table.frameOfCell(atColumn: 0, row: 0).minX
        if let stack = bar?.stack, stack.edgeInsets.left != left { stack.edgeInsets.left = left }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true
        checkedFor = []
        watchShown()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        watchShown()
    }
    private func watchShown() {
        watched.key = shown ? app.workbench.workspaceId : nil
        // Until the first answer, an empty list would read as no databases: the wait says it is on its way.
        if shown, let wid = app.workbench.workspaceId, app.latest(DatabasesEvent.self, wid) == nil {
            loading.wait(String(localized: "Reading the databases…"))
        } else {
            loading.show(nil)
        }
        reload()
    }

    // MARK: Rows

    func reload() {
        let event = app.latest(DatabasesEvent.self, workspace)
        if event != nil, loading.showing {   // a wait on screen stays its moment, and then gives way to the answer
            Task {
                await loading.settled()
                loading.show(nil)
                reload()
            }
            return
        }
        if event != nil { loading.show(nil) }
        let databases = event?.databases ?? [], library = event?.library ?? []
        if event != nil {
            if library.count > libraryCount { libraryOpen = true }   // one was just imported or added: show it
            libraryCount = library.count
        }
        rows =
            DatabasePanelList(
                databases: databases, library: library, runs: event?.runs ?? [],
                find: search.stringValue.trimmingCharacters(in: .whitespaces).lowercased(), libraryOpen: libraryOpen,
                activityOpen: activityOpen, only: only, folded: folded, health: health, libraryHealth: libraryHealth
            ).rows
        empty.show(
            event != nil && databases.isEmpty && library.isEmpty ? String(localized: "No Databases") : nil,
            symbol: DatabaseLook.symbol,
            text: String(
                localized:
                    "Kelp looks in compose files, .env, config/database.yml, .idea and SQLite or DuckDB files of the project."
            ),
            buttons: [addButton])
        table.reloadData()
        markOpen()
        alignSearch()
        check(databases, library: false)
        if libraryOpen { check(library, library: true) }
    }

    /// Selects the database the focused tab shows, so the tab and its row read as one.
    private func markOpen() {
        let open = app.workbench.focusedTab.flatMap(DatabaseURI.init)
        let index = rows.firstIndex { row in
            guard case .database(let db, _) = row, let open else { return false }
            return open.worktree == workspace && open.name == db.name
        }
        guard table.selectedRowIndexes.count < 2 else { return }   // the user picked several: keep the selection
        if let index {
            if table.selectedRow != index { table.selectRowIndexes([index], byExtendingSelection: false) }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    /// Whether `db` is a copy whose own database is listed with it, in which case the copy shows under that database.
    static func nested(_ db: DatabaseInfo, among all: [DatabaseInfo]) -> Bool {
        guard let copy = db.copy else { return false }
        return all.contains { $0.name == copy.of && $0.name != db.name }
    }

    /// Reads the dots once for the databases there are now, not at every run that changes the panel: the project's, or
    /// with `library` All My Databases', which don't change with the workspace.
    private func check(_ databases: [DatabaseInfo], library: Bool) {
        let now = databases.map { $0.name + $0.address }
        let checked = library ? \DatabasesPanel.libraryCheckedFor : \DatabasesPanel.checkedFor
        guard shown, now != self[keyPath: checked], !databases.isEmpty else { return }
        self[keyPath: checked] = now
        let wid = workspace
        Task {
            let answer = await app.quiet(DatabaseStatus(worktreeId: wid, library: library ? true : nil)) ?? []
            guard library || wid == workspace else { return }
            self[keyPath: library ? \DatabasesPanel.libraryHealth : \DatabasesPanel.health] =
                Dictionary(answer.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            reload()
        }
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    private lazy var addButton = NSButton(
        title: String(localized: "Add Database…"), target: self, action: #selector(addDatabase))
    @objc func addDatabase() {
        let wid = workspace, app = app
        Task { await DatabaseSheet.run(app, worktreeId: wid, editing: nil) }
    }

    // MARK: Table view

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    /// A database of All My Databases in no group lines up with the cards' rows, so its selection sits where theirs
    /// does. The Asks heading does nothing on a click, so it doesn't light up under the pointer; the other two fold.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let loose = if case .database(_, library: true) = rows[row], cards[row] == nil { true } else { false }
        let inert = if case .heading(.asks) = rows[row] { true } else { false }
        let view = ListRowView(inset: loose ? 10 : 6, lights: { _ in !inert })
        view.card = card(row)
        return view
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .heading, .problem, .project, .use, .group: false
        default: true
        }
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let base =
            switch rows[row] {
            case .heading: TextSize.of(Metrics.rowSection)
            case .database, .asks, .use(empty: true): TextSize.of(Metrics.rowTwoLine)
            case .problem: TextSize.of(Metrics.row) - 4
            case .run, .group, .project, .use: TextSize.of(Metrics.row)
            }
        let part = cards[row]
        return base + (part?.first == true ? ListRowView.cardPad : 0) + (part?.last == true ? ListRowView.cardPad : 0)
    }

    /// The part of a card a row draws, in the card's colour: a group's own colour, or the project's card lit while a
    /// drag is over it.
    private func card(_ row: Int) -> ListRowView.Card? {
        guard var part = cards.indices.contains(row) ? cards[row] : nil else { return nil }
        switch Self.owner(rows, row) {
        case "project"?: if dropOnProject { part.fill = .fillTint(.controlAccentColor) }
        case let id?:
            if let color = color(of: String(id.dropFirst(2)), group: true) { part.fill = .fillTint(color.color) }
        case nil: break
        }
        return part
    }

    /// Which card a row is on: the project's card ("project"), a group's card ("g:" and its name), or none.
    static func owner(_ rows: [Row], _ row: Int) -> String? {
        switch rows[row] {
        case .project, .use, .database(_, library: false): "project"
        case .group(let name, _): "g:" + name
        case .database(let db, library: true): db.groupName.map { "g:" + $0 }
        case .problem: row > 0 ? owner(rows, row - 1) : nil
        default: nil
        }
    }

    static func cards(_ rows: [Row]) -> [ListRowView.Card?] {
        let owners = rows.indices.map { owner(rows, $0) }
        return owners.indices.map { i in
            guard let id = owners[i] else { return nil }
            return ListRowView.Card(
                first: i == 0 || owners[i - 1] != id, last: i == owners.count - 1 || owners[i + 1] != id)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let parts = DatabasePanelRows(panel: self)
        return switch rows[row] {
        case .heading(let heading):
            parts.heading(heading, libraryOpen: libraryOpen, activityOpen: activityOpen, only: only)
        case .asks(let run): parts.asks(run)
        case .database(let db, let library):
            parts.database(
                db, library: library, health: library ? libraryHealth[db.name] : health[db.name],
                used: library && projectNames.contains(db.name), color: color(of: db.name, group: false),
                under: !library && Self.nested(db, among: app.latest(DatabasesEvent.self, workspace)?.databases ?? []))
        case .problem(let db, let checked): parts.problem(db, checked)
        case .project(let count): parts.projectHead(count: count)
        case .use(let empty): parts.use(empty: empty)
        case .group(let name, let count):
            parts.group(name, count: count, open: !folded.contains(name), color: color(of: name, group: true))
        case .run(let run): parts.ran(run)
        }
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation op: NSTableView.DropOperation
    ) -> NSDragOperation {
        Self.droppedFile(info) != nil ? .copy : validateDatabases(info, row: row, op: op)
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let path = Self.droppedFile(info) else { return acceptDatabases(info, row: row, op: dropOperation) }
        let address: DatabaseAddress
        do { address = try DatabaseAddress.parse(path) } catch { return false }   // a path always parses: never here
        let wid = workspace, app = app
        Task { await DatabaseSheet.run(app, worktreeId: wid, adding: address) }
        return true
    }

    private static func droppedFile(_ info: any NSDraggingInfo) -> String? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first {
            ["sqlite", "sqlite3", "db", "db3", "duckdb", "ddb"].contains($0.pathExtension.lowercased())
        }?
        .path
    }

    static func mention(_ table: String, in db: String) -> String {
        "the table \(table) in \(db) (kelp db schema \(quoted(table)) --db \(quoted(db)))"
    }
    /// What a database dragged onto an agent's terminal becomes: its name and how to read it.
    static func mention(database db: String) -> String { "the database \(db) (kelp db schema --db \(quoted(db)))" }
    private static func quoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) } ? word : ShellQuote.word(word)
    }
}
