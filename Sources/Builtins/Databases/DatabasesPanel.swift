import AppKit
import Core
import DesignKit
import KelpKit

/// The databases of the workspace on screen and what was run on them, by whom: each database with what agents may do
/// with it, an agent's change that waits for the user under it, then the latest runs (the agents', and the user's
/// changes). A database opens its tab; a run opens its rows; a change that asks shows its chat.
@MainActor
final class DatabasesPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row {
        case heading(String, add: Bool)
        case database(DatabaseInfo)
        case asks(DatabaseRun)
        case run(DatabaseRun)
    }

    private let app: AppModel
    private let table = NSTableView()
    private let empty = EmptyStateView()
    private var rows: [Row] = []
    private lazy var watched = Watched(.databases, in: app)
    private var shown = false
    private var workspace: String { app.workbench.workspaceId ?? "" }

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
        table.action = #selector(open)
        table.menu = NSMenu()
        table.menu?.delegate = self
        let content = NSView()
        content.pin(scroll)
        empty.place(in: content)
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] _ in
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

    private func reload() {
        let event = app.latest(DatabasesEvent.self, workspace)
        let project = app.projectName(app.worktree(workspace)?.repoId) ?? String(localized: "This Project")
        var list: [Row] = []
        if let event, !event.databases.isEmpty {
            list.append(.heading(project, add: true))
            for db in event.databases {
                list.append(.database(db))
                list += event.runs.filter { $0.database == db.name && $0.state == .asks }.map(Row.asks)
            }
            // The user's own reads (browsing tables in a tab) aren't news here; what agents ran and any change are.
            let runs = event.runs.filter { $0.state != .asks && ($0.session != nil || $0.changed != nil) }.prefix(30)
            if !runs.isEmpty { list += [.heading(String(localized: "Recent Queries"), add: false)] + runs.map(Row.run) }
        }
        rows = list
        empty.show(
            event != nil && rows.isEmpty ? String(localized: "No Databases") : nil, symbol: DatabaseLook.symbol,
            text: String(
                localized: "Kelp looks in compose files, .env, config/database.yml and SQLite files of the project."),
            buttons: [addButton])
        table.reloadData()
    }

    private lazy var addButton = NSButton(
        title: String(localized: "Add Database…"), target: self, action: #selector(addDatabase))
    @objc private func addDatabase() {
        let wid = workspace, app = app
        Task { await DatabaseSheet.run(app, worktreeId: wid, editing: nil) }
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .heading = rows[row] { return false }
        return true
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .heading: TextSize.of(Metrics.rowSection)
        case .database: TextSize.of(Metrics.rowTwoLine)
        case .asks, .run: TextSize.of(Metrics.row)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let title, let add): heading(title, add: add)
        case .database(let db): database(db)
        case .asks(let run): asks(run)
        case .run(let run): ran(run)
        }
    }

    private func heading(_ title: String, add: Bool) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .ui(11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        var views: [NSView] = [label, NSView()]
        if add {
            views.append(
                IconButton(.symbol("plus"), tip: String(localized: "Add Database…")) { [weak self] in
                    self?.addDatabase()
                })
        }
        return line(views, inset: Metrics.inset, trailing: Metrics.insetTrailing)
    }

    private func database(_ db: DatabaseInfo) -> NSView {
        let icon = NSImageView(image: .symbol(DatabaseLook.symbol))
        icon.symbolConfiguration = .chrome()
        icon.contentTintColor = db.production ? .textRed : .secondaryLabelColor
        let name = label(db.name, font: .ui(12, weight: .medium))
        let detail = label(DatabaseLook.detail(db), font: .ui(11), color: .secondaryLabelColor)
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        let access = label(
            db.production ? String(localized: "production") : DatabaseLook.access(db), font: .ui(10, weight: .semibold),
            color: db.production ? .textRed : .secondaryLabelColor)
        access.toolTip = String(localized: "What agents may do: \(DatabaseLook.title(db.agentAccess))")
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return line([icon, text, NSView(), access], inset: Metrics.inset, trailing: Metrics.inset)
    }

    private func asks(_ run: DatabaseRun) -> NSView {
        let session = run.session.flatMap(app.session)
        let icon = NSImageView(image: app.catalog.icon(session?.agent, size: 14) ?? .symbol("exclamationmark.bubble"))
        let what =
            run.changed.map { String(localized: "Asks to change \($0) rows") }
            ?? String(localized: "Asks to run a change")
        let text = label(what, font: .ui(12), color: .textOrange)
        text.toolTip = run.sql
        return line([icon, text, NSView()], inset: Metrics.inset + 20, trailing: Metrics.inset)
    }

    private func ran(_ run: DatabaseRun) -> NSView {
        let session = run.session.flatMap(app.session)
        let icon = NSImageView(image: session.flatMap { app.catalog.icon($0.agent, size: 14) } ?? .symbol("person"))
        icon.contentTintColor = .secondaryLabelColor
        let sql = label(Self.oneLine(run.sql), font: .uiMono(11))
        sql.toolTip = [run.sql, run.error].compactMap { $0 }.joined(separator: "\n\n")
        let end = label(Self.outcome(run), font: .uiDigits(11), color: Self.color(run.state))
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return line([icon, sql, NSView(), end], inset: Metrics.inset, trailing: Metrics.inset)
    }

    static func oneLine(_ sql: String) -> String {
        sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// "200 · 2m", "3 changed · 1h", or what stopped it.
    static func outcome(_ run: DatabaseRun) -> String {
        switch run.state {
        case .done:
            let count = run.changed.map { String(localized: "\($0) changed") } ?? run.rows.map { "\($0)" }
            return [count, shortAgo(run.at)].compactMap { $0 }.joined(separator: " · ")
        case .asks: return String(localized: "asks")
        case .denied: return String(localized: "denied")
        case .refused: return String(localized: "refused")
        case .failed: return String(localized: "failed")
        }
    }

    static func color(_ state: DatabaseRun.State) -> NSColor {
        switch state {
        case .done, .denied: .secondaryLabelColor
        case .asks: .textOrange
        case .refused, .failed: .textRed
        }
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func line(_ views: [NSView], inset: CGFloat, trailing: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.spacing = Metrics.gapWide
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: trailing)
        return stack
    }

    // MARK: Actions

    @objc private func open() {
        guard rows.indices.contains(table.clickedRow) else { return }
        switch rows[table.clickedRow] {
        case .heading: break
        case .database(let db): app.workbench.open(DatabaseURI(worktree: workspace, name: db.name).uri)
        case .asks(let run):
            app.workbench.open(DatabaseURI(worktree: workspace, name: run.database, run: run.id).uri)
        case .run(let run):
            app.workbench.open(DatabaseURI(worktree: workspace, name: run.database, run: run.id).uri)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else {
            menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
            return
        }
        let app = app, wid = workspace
        switch rows[table.clickedRow] {
        case .heading: menu.add(String(localized: "Add Database…")) { [weak self] in self?.addDatabase() }
        case .database(let db): DatabaseMenu.fill(menu, db, app: app, worktreeId: wid)
        case .asks(let run), .run(let run):
            menu.add(String(localized: "Show Rows")) {
                app.workbench.open(DatabaseURI(worktree: wid, name: run.database, run: run.id).uri)
            }
            if let session = run.session, app.session(session) != nil {
                menu.add(String(localized: "Show the Chat That Ran It")) { app.workbench.focus(session: session) }
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy SQL")) { copyText(run.sql) }
        }
    }
}

/// A database's menu, in the panel and on its tab: open it, what agents may do, production, its address, edit, forget.
@MainActor
enum DatabaseMenu {
    static func fill(_ menu: NSMenu, _ db: DatabaseInfo, app: AppModel, worktreeId: String) {
        menu.add(String(localized: "Open")) {
            app.workbench.open(DatabaseURI(worktree: worktreeId, name: db.name).uri)
        }
        menu.addItem(.separator())
        let agents = NSMenu()
        for access in DatabaseInfo.Access.allCases {
            let item = agents.add(DatabaseLook.title(access)) {
                var changed = db
                changed.access = access
                Task { await app.call(DatabaseSave(worktreeId: worktreeId, database: changed)) }
            }
            item.state = db.access == access ? .on : .off
        }
        menu.setSubmenu(
            agents, for: menu.addItem(withTitle: String(localized: "Agents"), action: nil, keyEquivalent: ""))
        menu.add(String(localized: "Production")) {
            var changed = db
            changed.production.toggle()
            Task { await app.call(DatabaseSave(worktreeId: worktreeId, database: changed)) }
        }.state = db.production ? .on : .off
        menu.addItem(.separator())
        menu.add(String(localized: "Copy Address")) { copyText(db.address) }
        if db.source == nil {
            menu.add(String(localized: "Edit…")) {
                Task { await DatabaseSheet.run(app, worktreeId: worktreeId, editing: db) }
            }
            menu.add(String(localized: "Forget")) {
                Task { await app.call(DatabaseRemove(worktreeId: worktreeId, name: db.name)) }
            }
        }
    }
}
