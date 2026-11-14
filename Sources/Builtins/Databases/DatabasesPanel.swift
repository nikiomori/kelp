import AppKit
import Core
import DesignKit
import KelpKit

/// The Databases panel: connections, as TablePlus' left column. Most urgent first: an agent's change that waits for
/// the user (Allow in the row), then the project's card (name, environment, "host : database", a dot that says
/// whether it answers, what agents may do as an icon; Use a Database… last), All My Databases with a card per group,
/// and what was run lately (by agent). Over it, a field that finds a database and the one +. A database opens its tab,
/// where its tables are.
@MainActor
final class DatabasesPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    enum Row {
        case heading(Heading)
        case asks(DatabaseRun)
        case database(DatabaseInfo, library: Bool)
        /// A group of All My Databases (TablePlus' group, DBeaver's folder, or one made here), its rows under it.
        case group(String, count: Int)
        case problem(DatabaseInfo, DatabaseHealth)
        /// The project's card: its own row, then its databases, then Use a Database… (`empty`: it uses none yet).
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
    /// The header every inspector panel has: 36 pt with its hairline.
    private var bar: Bar?
    var rows: [Row] = [] {
        didSet { cards = Self.cards(rows) }
    }
    /// Each row's part of a card (the project's, a group's), nil for one on its own.
    private var cards: [ListRowView.Card?] = []
    /// A drag of All My Databases is over the project's card: it lights up as where they'd go.
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

    /// What the user unfolded, and what Kelp read for it.
    private var libraryOpen = true, activityOpen = true
    /// All My Databases' groups folded, by name: kept on this Mac.
    var folded = Set(UserDefaults.standard.stringArray(forKey: "databases.foldedGroups") ?? []) {
        didSet { UserDefaults.standard.set(folded.sorted(), forKey: "databases.foldedGroups") }
    }
    /// The folded group a drag rests on, and since when: it opens after a moment, as a folder does in Finder.
    var springGroup: (name: String, since: Date)?
    /// The colour under the pointer in a row's menu, shown on the row until the menu closes.
    var colorPreview: (name: String, group: Bool, color: ProjectColor?)? { didSet { table.reloadData() } }
    private var health: [String: DatabaseHealth] = [:]
    /// All My Databases' dots, read once the section is open.
    private var libraryHealth: [String: DatabaseHealth] = [:], libraryCheckedFor: [String] = []
    private var libraryCount = Int.max   // the first read only counts
    /// The databases (by address) the dots were last read for: read again when that changes, not at each run.
    private var checkedFor: [String] = []
    /// Activity of one agent's session only; nil: everyone's.
    private var only: String?

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
        table.allowsMultipleSelection = true   // several of All My Databases into a group, or into the project
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        // a .sqlite or .duckdb file dropped in: Add Database with it; one of All My Databases: a group, or used here
        table.registerForDraggedTypes([.fileURL, .kelpDatabase, .kelpDatabaseGroup])
        table.dragLeft = { [weak self] in self?.dropOnProject = false }
        search.placeholderString = String(localized: "Find a Database")
        search.delegate = self
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        // The one way to add a database (or import them): there whether the project has any or not.
        let add = IconButton(.symbol("plus"), tip: String(localized: "Add Database…")) { [weak self] in
            self?.addDatabase()
        }
        let bar = Bar.panel([search], [add], stretching: search)
        self.bar = bar
        let content = stacked(bar, scroll)
        empty.place(in: content)
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
    /// The field starts where the rows' badges do: the list's cells sit past its own edge.
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
        reload()
    }

    // MARK: Rows

    func reload() {
        let event = app.latest(DatabasesEvent.self, workspace)
        let databases = event?.databases ?? [], library = event?.library ?? [], runs = event?.runs ?? []
        let find = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var list: [Row] = []
        let asking = runs.filter { $0.state == .asks }
        if !asking.isEmpty { list += [.heading(.asks)] + asking.map(Row.asks) }
        // The project's own card even empty: All My Databases under it alone read as this project's.
        if !databases.isEmpty || !library.isEmpty {
            list.append(.project(count: databases.count))
            for db in databases { list += rows(of: db, library: false, find: find) }
            if !library.isEmpty { list.append(.use(empty: databases.isEmpty)) }
        }
        if event != nil {
            if library.count > libraryCount { libraryOpen = true }   // just imported or added: shown
            libraryCount = library.count
        }
        if !library.isEmpty {
            list.append(.heading(.library(library.count)))
            if libraryOpen || !find.isEmpty { list += libraryRows(library, find: find) }
        }
        // The user's own reads (browsing tables in a tab) aren't news here; what agents ran and any change are.
        let ran = runs.filter { $0.state != .asks && ($0.session != nil || $0.changed != nil) }
            .filter { only == nil || $0.session == only }.prefix(30)
        if !ran.isEmpty, find.isEmpty {
            list.append(.heading(.activity(ran.count)))
            if activityOpen { list += ran.map(Row.run) }
        }
        rows = list
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
        checkHealth(databases)
        if libraryOpen { checkLibrary(library) }
    }

    /// The database the focused tab shows, picked in the list: the tab and its row read as one.
    private func markOpen() {
        let open = app.workbench.focusedTab.flatMap(DatabaseURI.init)
        let index = rows.firstIndex { row in
            guard case .database(let db, _) = row, let open else { return false }
            return open.worktree == workspace && open.name == db.name
        }
        guard table.selectedRowIndexes.count < 2 else { return }   // several picked by hand: theirs to keep
        if let index {
            if table.selectedRow != index { table.selectRowIndexes([index], byExtendingSelection: false) }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    /// The groups by name, each with its databases (all of them while finding: a group's name finds them too), then
    /// the ones in none.
    private func libraryRows(_ library: [DatabaseInfo], find: String) -> [Row] {
        let (groups, loose) = Self.grouped(library)
        var out: [Row] = []
        for (name, members) in groups {
            let shown = members.flatMap { rows(of: $0, library: true, find: find) }
            if shown.isEmpty { continue }
            out.append(.group(name, count: members.count))
            if !folded.contains(name) || !find.isEmpty { out += shown }
        }
        return out + loose.flatMap { rows(of: $0, library: true, find: find) }
    }

    /// A database's row, and what's wrong with it under it; found by its name, address or environment.
    private func rows(of db: DatabaseInfo, library: Bool, find: String) -> [Row] {
        let words = [db.name, db.address, DatabaseLook.title(db.stage), db.group ?? ""].joined(separator: " ")
        if !find.isEmpty, !words.lowercased().contains(find) { return [] }
        var out: [Row] = [.database(db, library: library)]
        if let checked = library ? libraryHealth[db.name] : health[db.name], checked.state != .ok,
            checked.state != .unknown
        {
            out.append(.problem(db, checked))
        }
        return out
    }

    static func key(_ name: String, library: Bool) -> String { (library ? "~" : "") + name }

    /// The dots, read once for the databases there are now: not at every run that changes the panel.
    private func checkHealth(_ databases: [DatabaseInfo]) {
        let now = databases.map { $0.name + $0.address }
        guard shown, now != checkedFor, !databases.isEmpty else { return }
        checkedFor = now
        let wid = workspace
        Task {
            let answer = await app.quiet(DatabaseStatus(worktreeId: wid)) ?? []
            guard wid == workspace else { return }
            health = Dictionary(answer.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            reload()
        }
    }

    private func checkLibrary(_ library: [DatabaseInfo]) {
        let now = library.map { $0.name + $0.address }
        guard shown, now != libraryCheckedFor, !library.isEmpty else { return }
        libraryCheckedFor = now
        let wid = workspace
        Task {
            let answer = await app.quiet(DatabaseStatus(worktreeId: wid, library: true)) ?? []
            libraryHealth = Dictionary(answer.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            reload()
        }
    }

    func controlTextDidChange(_ n: Notification) { reload() }

    private lazy var addButton = NSButton(
        title: String(localized: "Add Database…"), target: self, action: #selector(addDatabase))
    @objc func addDatabase() {
        let wid = workspace, app = app
        Task { await DatabaseSheet.run(app, worktreeId: wid, editing: nil) }
    }

    // MARK: Table view

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    /// A database of All My Databases in no group lines up with the cards' rows: its selection where theirs is.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let loose = if case .database(_, library: true) = rows[row], cards[row] == nil { true } else { false }
        let view = ListRowView(inset: loose ? 10 : 6)
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

    /// Its part of a card, in the card's colour: a group's own, the project's lit while a drag is over it.
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

    /// Which card a row is on: the project's ("project"), a group's ("g:" and its name), or none.
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
                used: library && projectNames.contains(db.name), color: color(of: db.name, group: false))
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
        do { address = try DatabaseAddress.parse(path) } catch { return false }   // a path always reads: never here
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
    /// A database dragged onto an agent's terminal: its name and where to read it.
    static func mention(database db: String) -> String { "the database \(db) (kelp db schema --db \(quoted(db)))" }
    private static func quoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) } ? word : ShellQuote.word(word)
    }

    // MARK: Clicks

    @objc private func clicked() {
        let index = table.clickedRow
        guard rows.indices.contains(index) else { return }
        let wid = workspace
        switch rows[index] {
        case .heading(.library): libraryOpen.toggle()
        case .heading(.activity): activityOpen.toggle()
        case .heading: return
        case .group(let name, _):
            if folded.remove(name) == nil { folded.insert(name) }
        case .database(let db, _):
            // ⌘ and ⇧ pick several (to drag or for the menu): a plain click opens it
            if !NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) { return }
            app.workbench.open(DatabaseURI(worktree: wid, name: db.name).uri)
            return
        case .asks(let run), .run(let run):
            app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            return
        case .use: return showUseMenu(at: index)
        case .problem, .project: return
        }
        table.crossfade(Motion.base)   // a fold: its rows fade out or in rather than snap (too many to move one by one)
        reload()
    }

    func answer(_ run: DatabaseRun, allow: Bool) {
        guard let sid = run.session else { return }
        Notifications.answer(app, sid, allow ? "allow" : "deny", question: app.session(sid)?.summary)
    }

    func start(_ db: DatabaseInfo) {
        let wid = workspace
        health[db.name] = DatabaseHealth(name: db.name, state: .unknown, reason: nil)
        reload()
        Task {
            _ = await app.call(DatabaseStart(worktreeId: wid, name: db.name))
            checkedFor = []
            reload()
        }
    }

    /// One of All My Databases, used in this project: its agents reach it from now on.
    func use(_ db: DatabaseInfo) {
        let wid = workspace
        Task { await app.call(DatabaseUse(worktreeId: wid, name: db.name)) }
    }

    func filter(_ session: String?) {
        only = session
        reload()
    }

    // MARK: Menu

    func menuDidClose(_ menu: NSMenu) { if colorPreview != nil { colorPreview = nil } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let app = app, wid = workspace
        guard rows.indices.contains(table.clickedRow) else {
            menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
            return
        }
        switch rows[table.clickedRow] {
        case .heading(.activity):
            let agents = Set((app.latest(DatabasesEvent.self, wid)?.runs ?? []).compactMap(\.session))
            menu.add(String(localized: "Everyone’s")) { [weak self] in self?.filter(nil) }.state =
                only == nil ? .on : .off
            for sid in agents.sorted() {
                guard let agent = app.session(sid) else { continue }
                menu.add(agent.title.isEmpty ? app.catalog.name(agent.agent) : agent.title) { [weak self] in
                    self?.filter(sid)
                }
                .state = only == sid ? .on : .off
            }
        case .heading: menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
        case .database(let db, let library):
            let picked = pickedLibrary(around: table.clickedRow)
            if picked.count > 1 { return fillMany(menu, picked) }
            DatabaseMenu.fill(menu, db, app: app, worktreeId: wid, library: library) { [weak self] in
                if library { self?.addGroupItems($0, [db]) }
                self?.addColorItem($0, db.name, group: false)
            }
        case .group(let name, _): fillGroup(menu, name)
        case .asks(let run), .run(let run):
            menu.add(String(localized: "Show Rows")) {
                app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            }
            if let session = run.session, app.session(session) != nil {
                menu.add(String(localized: "Show the Chat That Ran It")) { app.workbench.focus(session: session) }
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy SQL")) { copyText(run.sql) }
        case .problem: break
        case .project, .use: menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
        }
    }
}
