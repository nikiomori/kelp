import AppKit
import Core
import DesignKit
import KelpKit

/// The Databases panel: connections, as TablePlus' left column. Most urgent first: an agent's change that waits for
/// the user (Allow in the row), then the project's databases (name, environment, "host : database", a dot that says
/// whether it answers, what agents may do as an icon), All My Projects, and what was run lately (by agent). Over it, a
/// field that finds a database and the one +. A database opens its tab, where its tables are.
@MainActor
final class DatabasesPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    enum Row {
        case heading(Heading)
        case asks(DatabaseRun)
        case database(DatabaseInfo, library: Bool)
        case problem(DatabaseInfo, DatabaseHealth)
        case run(DatabaseRun)
    }
    enum Heading: Equatable {
        case asks, project(String), library(Int), activity(Int)
    }

    let app: AppModel
    private let table = NSTableView()
    private let search = NSSearchField()
    private let empty = EmptyStateView()
    private var rows: [Row] = []
    private lazy var watched = Watched(.databases, in: app)
    private var shown = false
    var workspace: String { app.workbench.workspaceId ?? "" }

    /// What the user unfolded, and what Kelp read for it.
    private var libraryOpen = true, activityOpen = true
    private var health: [String: DatabaseHealth] = [:]
    /// All My Projects' dots, read once the section is open.
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
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.fileURL])   // a .sqlite or .duckdb file dropped in: Add Database with it
        search.placeholderString = String(localized: "Find a Database")
        search.delegate = self
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        // The one way to add a database (or import them): there whether the project has any or not.
        let add = IconButton(.symbol("plus"), tip: String(localized: "Add Database…")) { [weak self] in
            self?.addDatabase()
        }
        let top = NSStackView(views: [search, add])
        top.spacing = Metrics.gap
        top.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.gapWide, bottom: Metrics.gap, right: Metrics.gapWide)
        let column = NSStackView(views: [top, scroll])
        column.orientation = .vertical
        column.spacing = 0
        let content = NSView()
        content.pin(column)
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
        if !databases.isEmpty {
            list.append(.heading(.project(app.projectName(app.worktree(workspace)?.repoId) ?? "")))
            for db in databases { list += rows(of: db, library: false, find: find) }
        }
        if event != nil {
            if library.count > libraryCount { libraryOpen = true }   // just imported or added: shown
            libraryCount = library.count
        }
        if !library.isEmpty {
            list.append(.heading(.library(library.count)))
            if libraryOpen || !find.isEmpty {
                for db in library { list += rows(of: db, library: true, find: find) }
            }
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
        checkHealth(databases)
        if libraryOpen { checkLibrary(library) }
    }

    /// A database's row, and what's wrong with it under it; found by its name, address or environment.
    private func rows(of db: DatabaseInfo, library: Bool, find: String) -> [Row] {
        let words = [db.name, db.address, DatabaseLook.title(db.stage), db.group ?? ""].joined(separator: " ")
        if !find.isEmpty, !words.lowercased().contains(find) { return [] }
        var out: [Row] = [.database(db, library: library)]
        if let h = library ? libraryHealth[db.name] : health[db.name], h.state != .ok, h.state != .unknown {
            out.append(.problem(db, h))
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
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .heading, .problem: false
        default: true
        }
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .heading: TextSize.of(Metrics.rowSection)
        case .database, .asks: TextSize.of(Metrics.rowTwoLine)
        case .problem: TextSize.of(Metrics.row) - 4
        case .run: TextSize.of(Metrics.row)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let parts = DatabasePanelRows(panel: self)
        return switch rows[row] {
        case .heading(let h): parts.heading(h, libraryOpen: libraryOpen, activityOpen: activityOpen, only: only)
        case .asks(let run): parts.asks(run)
        case .database(let db, let library):
            parts.database(db, library: library, health: library ? libraryHealth[db.name] : health[db.name])
        case .problem(let db, let h): parts.problem(db, h)
        case .run(let run): parts.ran(run)
        }
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation op: NSTableView.DropOperation
    ) -> NSDragOperation {
        Self.droppedFile(info) == nil ? [] : .copy
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let path = Self.droppedFile(info) else { return false }
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
        "the table \(table) in \(db) (kelp db schema \(db) \(table))"
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
        case .database(let db, _):
            app.workbench.open(DatabaseURI(worktree: wid, name: db.name).uri)
            return
        case .asks(let run), .run(let run):
            app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            return
        case .problem: return
        }
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

    func filter(_ session: String?) {
        only = session
        reload()
    }

    // MARK: Menu

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
                guard let s = app.session(sid) else { continue }
                menu.add(s.title.isEmpty ? app.catalog.name(s.agent) : s.title) { [weak self] in self?.filter(sid) }
                    .state = only == sid ? .on : .off
            }
        case .heading: menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
        case .database(let db, let library):
            DatabaseMenu.fill(menu, db, app: app, worktreeId: wid, library: library)
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
        }
    }
}

/// A database's menu, in the panel and on its tab: open it, what agents may do, production, its address, edit, forget;
/// one of All My Projects is used in this project instead.
@MainActor
enum DatabaseMenu {
    static func fill(_ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String, library: Bool = false) {
        menu.add(String(localized: "Open")) {
            app.workbench.open(DatabaseURI(worktree: worktreeId, name: db.name).uri)
        }
        menu.addItem(.separator())
        if library {
            let project = app.projectName(app.worktree(worktreeId)?.repoId) ?? ""
            menu.add(String(localized: "Use in \(project)")) {
                Task { await app.call(DatabaseUse(worktreeId: worktreeId, name: db.name)) }
            }
        } else {
            menu.setSubmenu(
                agents(db, app: app, worktreeId: worktreeId),
                for: menu.addItem(withTitle: String(localized: "Agents"), action: nil, keyEquivalent: ""))
            production(menu, db, app: app, worktreeId: worktreeId)
            // A copy to change on this branch without touching the project's (`db.copy`): files and a Postgres here.
            if !db.production, db.engine != .mysql, let branch = app.worktree(worktreeId)?.branch {
                menu.add(String(localized: "Copy for \(branch)")) {
                    Task {
                        guard let copy = await app.call(DatabaseCopy(worktreeId: worktreeId, database: db.name)) else {
                            return
                        }
                        Banner.show(String(localized: "\(copy.name) is \(branch)'s copy of \(db.name)."))
                        app.workbench.open(DatabaseURI(worktree: worktreeId, name: copy.name).uri)
                    }
                }
            }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Address")) { copyText(db.address) }
        if !db.engine.isFile {   // another database of the same server: the form, filled in, under a new name
            menu.add(String(localized: "Duplicate…")) {
                var copy = db
                copy.name = ""
                copy.source = nil
                Task { await DatabaseSheet.run(app, worktreeId: worktreeId, adding: DatabaseAddress(database: copy)) }
            }
        }
        if db.source == nil {
            menu.add(String(localized: "Edit…")) {
                Task { await DatabaseSheet.run(app, worktreeId: worktreeId, editing: db) }
            }
            menu.add(String(localized: "Forget")) {
                Task { await app.call(DatabaseRemove(worktreeId: worktreeId, name: db.name, library: library)) }
            }
        }
    }

    /// What agents may do, a choice each; the panel's access icon shows the same menu.
    static func agents(_ db: DatabaseInfo, app: AppModel, worktreeId: String) -> NSMenu {
        let agents = NSMenu()
        for access in DatabaseInfo.Access.allCases {
            let item = agents.add(DatabaseLook.title(access)) {
                var changed = db
                changed.access = access
                Task { await app.call(DatabaseSave(worktreeId: worktreeId, database: changed)) }
            }
            item.state = db.access == access ? .on : .off
            item.image = .symbol(DatabaseLook.accessSymbol(access))
        }
        return agents
    }

    /// Local, Development, Staging, Production. Leaving Production (agents get more than reading) is said first.
    private static func production(_ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String) {
        let stages = NSMenu()
        for stage in DatabaseInfo.Stage.allCases {
            let item = stages.add(DatabaseLook.title(stage)) {
                var changed = db
                changed.set(stage: stage)
                Task {
                    if db.production, stage != .production {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Let agents change \(db.name)?")
                        alert.informativeText = String(
                            localized:
                                "\(db.address) stops being production: agents get what Agents says, \(DatabaseLook.title(changed.access)), and their changes reach it."
                        )
                        alert.addButton(withTitle: String(localized: "Make It \(DatabaseLook.title(stage))"))
                        alert.addButton(withTitle: String(localized: "Cancel"))
                        guard await runSheet(alert) == .alertFirstButtonReturn else { return }
                    }
                    await app.call(DatabaseSave(worktreeId: worktreeId, database: changed))
                }
            }
            item.state = db.stage == stage ? .on : .off
            item.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                DatabaseLook.color(stage).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
        }
        menu.setSubmenu(
            stages, for: menu.addItem(withTitle: String(localized: "Environment"), action: nil, keyEquivalent: ""))
    }
}
