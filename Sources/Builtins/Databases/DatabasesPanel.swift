import AppKit
import Core
import DesignKit
import KelpKit

/// The Databases panel, most urgent first: an agent's change that waits for the user (Allow in the row), then the
/// project's databases, each with a dot that says whether it answers, what agents may do with it as an icon, and its
/// schemas and tables a click away; then All My Projects (the user's own, folded) and what was run lately (folded,
/// by agent). Over it, a field that finds a table in any of them. A database opens its tab, a table its rows.
@MainActor
final class DatabasesPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    enum Row {
        case heading(Heading)
        case asks(DatabaseRun)
        case database(DatabaseInfo, library: Bool)
        case problem(DatabaseInfo, DatabaseHealth)
        case schema(database: String, name: String)
        case table(database: String, DatabaseSchema.Table, depth: Int)
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
    private var expanded = Set<String>(), libraryOpen = false, activityOpen = true
    private var schemas: [String: DatabaseSchema] = [:]
    private var health: [String: DatabaseHealth] = [:]
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
        search.placeholderString = String(localized: "Find a Table")
        search.delegate = self
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        let top = NSStackView(views: [search])
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
            self?.expanded = []
            self?.schemas = [:]
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
    }

    /// A database's row, what's wrong with it, and its schemas and tables when it's unfolded (or a table's name is
    /// searched for).
    private func rows(of db: DatabaseInfo, library: Bool, find: String) -> [Row] {
        let key = Self.key(db.name, library: library)
        let tables = schemas[key]?.tables ?? []
        let matching = find.isEmpty ? tables : tables.filter { $0.name.lowercased().contains(find) }
        if !find.isEmpty, matching.isEmpty, !db.name.lowercased().contains(find) { return [] }
        var out: [Row] = [.database(db, library: library)]
        if !library, let h = health[db.name], h.state != .ok, h.state != .unknown { out.append(.problem(db, h)) }
        guard expanded.contains(key) || !find.isEmpty else { return out }
        // "public.orders" is "orders"; other schemas are folders of their own when there's more than one.
        let bySchema = Dictionary(grouping: matching) { t in
            t.name.contains(".") ? String(t.name.split(separator: ".")[0]) : ""
        }
        if bySchema.count <= 1 {
            out += matching.map { .table(database: key, $0, depth: 1) }
        } else {
            for schema in bySchema.keys.sorted() {
                out.append(.schema(database: key, name: schema.isEmpty ? "public" : schema))
                out += (bySchema[schema] ?? []).map { .table(database: key, $0, depth: 2) }
            }
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

    func toggle(_ db: DatabaseInfo, library: Bool) {
        let key = Self.key(db.name, library: library)
        if expanded.remove(key) == nil {
            expanded.insert(key)
            if schemas[key] == nil { load(db.name, key: key) }
        }
        reload()
    }

    private func load(_ name: String, key: String) {
        let wid = workspace
        Task {
            guard let schema = await app.quiet(DatabaseSchemaRead(worktreeId: wid, database: name)) else { return }
            schemas[key] = schema
            reload()
        }
    }

    func controlTextDidChange(_ n: Notification) {
        // A table is looked for in every database: read the ones not read yet.
        if !search.stringValue.isEmpty {
            let event = app.latest(DatabasesEvent.self, workspace)
            for db in event?.databases ?? [] where schemas[db.name] == nil && health[db.name]?.state != .down {
                schemas[db.name] = DatabaseSchema(tables: [])
                load(db.name, key: db.name)
            }
        }
        reload()
    }

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
        case .heading, .problem, .schema: false
        default: true
        }
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .heading: TextSize.of(Metrics.rowSection)
        case .database, .asks: TextSize.of(Metrics.rowTwoLine)
        case .problem: TextSize.of(Metrics.row) - 4
        case .schema, .table, .run: TextSize.of(Metrics.row)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let parts = DatabasePanelRows(panel: self)
        return switch rows[row] {
        case .heading(let h): parts.heading(h, libraryOpen: libraryOpen, activityOpen: activityOpen, only: only)
        case .asks(let run): parts.asks(run)
        case .database(let db, let library):
            parts.database(
                db, library: library, open: expanded.contains(Self.key(db.name, library: library)),
                health: library ? nil : health[db.name])
        case .problem(let db, let h): parts.problem(db, h)
        case .schema(_, let name): parts.schema(name)
        case .table(_, let t, let depth): parts.table(t, depth: depth)
        case .run(let run): parts.ran(run)
        }
    }

    /// A table dragged out (onto an agent's terminal, a note) is its name and where to read it.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .table(let key, let t, _) = rows[row] else { return nil }
        return Self.mention(t.name, in: key) as NSString
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

    static func mention(_ table: String, in key: String) -> String {
        let db = key.hasPrefix("~") ? String(key.dropFirst()) : key
        return "the table \(table) in \(db) (kelp db schema \(db) \(table))"
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
        case .database(let db, _):   // its chevron unfolds it (a button of its own)
            app.workbench.open(DatabaseURI(worktree: wid, name: db.name).uri)
            return
        case .table(let key, let t, _):
            let name = key.hasPrefix("~") ? String(key.dropFirst()) : key
            app.workbench.open(DatabaseURI(worktree: wid, name: name, table: t.name).uri)
            return
        case .asks(let run), .run(let run):
            app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            return
        case .problem, .schema: return
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
        case .table(let key, let t, _):
            let name = key.hasPrefix("~") ? String(key.dropFirst()) : key
            menu.add(String(localized: "Open")) {
                app.workbench.open(DatabaseURI(worktree: wid, name: name, table: t.name).uri)
            }
            if !key.hasPrefix("~"), let agent = DatabaseTab.agent(app, worktree: wid) {
                menu.add(String(localized: "Ask \(app.catalog.name(agent.agent)) About \(t.name)")) {
                    Task {
                        let text = "About " + Self.mention(t.name, in: key) + ": "
                        guard await app.call(SessionSend(id: agent.id, text: text, enter: false)) != nil else { return }
                        app.workbench.focus(session: agent.id)
                    }
                }
            }
            menu.add(String(localized: "Copy Name")) { copyText(t.name) }
        case .asks(let run), .run(let run):
            menu.add(String(localized: "Show Rows")) {
                app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            }
            if let session = run.session, app.session(session) != nil {
                menu.add(String(localized: "Show the Chat That Ran It")) { app.workbench.focus(session: session) }
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy SQL")) { copyText(run.sql) }
        case .problem, .schema: break
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

    private static func production(_ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String) {
        menu.add(String(localized: "Production")) {
            var changed = db
            changed.production.toggle()
            Task {
                // Raising what agents may do is said in words first: the rest of the menu only ever lowers it here.
                if !changed.production {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Let agents change \(db.name)?")
                    alert.informativeText = String(
                        localized:
                            "\(db.address) stops being production: agents get what Agents says, \(DatabaseLook.title(db.access)), and their changes reach it."
                    )
                    alert.addButton(withTitle: String(localized: "Not Production"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    guard await runSheet(alert) == .alertFirstButtonReturn else { return }
                }
                await app.call(DatabaseSave(worktreeId: worktreeId, database: changed))
            }
        }.state = db.production ? .on : .off
    }
}
