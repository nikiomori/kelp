import AppKit
import Core
import DesignKit
import KelpKit

/// Skills & MCP: what the chat looked at last in the workspace on screen gets besides the prompt (its skills, MCP
/// servers and instruction files, as it reported them at its start), or what a new chat there would get when it has no
/// record. Read when the panel shows, and again when the workspace or the chat changes. A switch is the project's:
/// chats started from then on follow it, and the one on screen can be restarted to.
@MainActor
final class AddonsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let app: AppModel
    private let table = NSTableView()
    private let empty = EmptyStateView()
    private let face = NSImageView()
    private let chatTitle = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private lazy var summary = NSStackView(views: [counts])
    private lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in
        self?.showMore()
    }
    private var addons: Addons?
    private var lines: [AddonLine] = []
    /// The groups folded or unfolded by hand: view state, not kept.
    private var toggled: Set<AddonGroup> = []
    private var shown = false
    private var loading: Task<Void, Never>?
    private let foot = NSStackView()
    private var laidOut: CGFloat = 0
    private let footNote = NSTextField(labelWithString: "")
    private var shownChat: Session?

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = table.plainList("addons")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        // The inspector's own title names the panel: its bar names the chat, as Source Control's names the branch.
        table.menu = NSMenu()
        table.menu?.delegate = self
        let add = IconButton(.symbol("plus"), tip: String(localized: "Add an MCP Server…")) { [weak self] in
            self?.addServer()
        }
        let header = Bar.panel([face, chatTitle], [add, more])
        chatTitle.font = .ui(TextSize.row, weight: .medium)
        chatTitle.lineBreakMode = .byTruncatingTail
        chatTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counts.font = .uiDigits(TextSize.caption)
        counts.textColor = .secondaryLabelColor
        counts.lineBreakMode = .byTruncatingTail
        counts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        summary.isHidden = true
        // A stack: the summary takes no room while it's hidden.
        let note = footNote
        note.font = .ui(TextSize.caption)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let restart = PointerButton(title: String(localized: "Restart This Chat")) { [weak self] in
            guard let self, let chat = shownChat else { return }
            AgentActions(app).restart(chat.id)
        }
        foot.setViews([note, NSView(), restart], in: .leading)
        foot.spacing = Metrics.gap
        foot.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        foot.isHidden = true
        let column = NSStackView(views: [header, summary, scroll, foot])
        column.orientation = .vertical
        column.spacing = 0
        for part in column.arrangedSubviews { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let root = NSView()
        root.pin(column)
        empty.place(in: root, under: header)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [weak self] in
            [self?.app.workbench.workspaceId, self?.chat?.id]
        } changed: { [weak self] _ in
            self?.reload()
        }
    }
    /// Rows lay themselves out for the panel's width: drawn again when it changes.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard abs(table.bounds.width - laidOut) >= 1 else { return }
        laidOut = table.bounds.width
        table.reloadData()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true
        reload()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        loading?.cancel()
    }

    /// The agent chat looked at last in the workspace on screen (the focused tab when it's one), else its newest.
    private var chat: Session? {
        let workspace = app.workbench.workspaceId
        if let last = app.workbench.lastSession.flatMap(app.session), last.worktreeId == workspace, last.isAgent {
            return last
        }
        return app.sessions.last { $0.worktreeId == workspace && $0.isChat && $0.isAgent && $0.status != .exited }
    }

    // MARK: Loading

    private func reload() {
        guard shown else { return }
        loading?.cancel()
        guard let workspace = app.workbench.workspaceId else { return show(nil, error: nil, chat: nil) }
        let chat = chat
        loading = Task { [weak self, app] in
            let answer = await app.tryCall(AddonsList(worktreeId: workspace, session: chat?.id))
            guard !Task.isCancelled else { return }
            self?.show(answer.value, error: answer.error, chat: chat)
        }
    }

    private func show(_ value: Addons?, error: String?, chat: Session?) {
        addons = value
        if let error {
            empty.showError(String(localized: "Couldn’t read the skills and servers"), text: error)
        } else {
            empty.show(
                (value?.items ?? []).isEmpty ? String(localized: "Nothing here yet") : nil, symbol: "powerplug",
                text: String(localized: "What agents get besides the prompt: skills, MCP servers, instruction files."))
        }
        let items = value?.items ?? []
        summary.isHidden = items.isEmpty || error != nil
        // The chat when the list is its own record (or nothing came back), else what a new one would get.
        let named = value.map { $0.chat ? chat : nil } ?? chat
        face.image = named.flatMap { app.catalog.icon($0.agent, size: Metrics.appIcon) }
        face.isHidden = face.image == nil
        chatTitle.stringValue =
            named.map(app.catalog.displayName) ?? (value == nil ? "" : String(localized: "What a new chat gets"))
        counts.stringValue = AddonGroups.summary(items, chat: value?.chat ?? false)
        // Something waits for a restart, and there's a chat to restart.
        shownChat = value?.chat == true ? chat : nil
        let gone = value?.gone ?? []
        foot.isHidden = shownChat == nil || (gone.isEmpty && !items.contains(where: AddonGroups.waits))
        footNote.stringValue = AddonGroups.footNote(gone: gone)
        footNote.toolTip = gone.isEmpty ? nil : gone.joined(separator: "\n")
        relist()
    }

    private func relist() {
        lines = AddonGroups.lines(addons?.items ?? [], toggled: toggled)
        table.reloadData()
    }

    /// The project's switch, then the list again: the daemon says what it is now.
    private func flip(_ key: String, on: Bool) {
        guard let workspace = app.workbench.workspaceId else { return }
        Task { [weak self, app] in
            await app.call(AddonsSet(worktreeId: workspace, key: key, on: on))
            self?.reload()
        }
    }

    private func addServer() {
        guard let workspace = app.workbench.workspaceId else { return }
        let project = app.projectName(app.worktree(workspace)?.repoId) ?? String(localized: "This Project")
        Task { [weak self, app] in
            guard let server = await AddonAddForm(project: project).ask() else { return }
            await app.call(
                AddonsAdd(worktreeId: workspace, name: server.name, entry: server.entry, project: server.project))
            self?.reload()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let workspace = app.workbench.workspaceId, lines.indices.contains(table.clickedRow) else { return }
        switch lines[table.clickedRow] {
        case .item(let addon, _), .problem(let addon):
            AddonMenu.fill(menu, addon, app: app, worktreeId: workspace) { [weak self] in self?.reload() }
        case .section, .group: break
        }
    }

    private func showMore() {
        let menu = NSMenu()
        menu.add(String(localized: "Refresh")) { [weak self] in self?.reload() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    @objc private func clicked() {
        guard lines.indices.contains(table.clickedRow), case .group(let g, _, _) = lines[table.clickedRow] else {
            return
        }
        if toggled.remove(g) == nil { toggled.insert(g) }
        relist()
    }

    // MARK: Table view

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch lines[row] {
        case .section: TextSize.of(Metrics.rowSection)
        case .problem: TextSize.of(Metrics.rowTwoLine)
        case .group, .item: TextSize.of(Metrics.row)
        }
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let rows = AddonRows(app: app) { [weak self] key, on in self?.flip(key, on: on) }
        let items = addons?.items ?? []
        return switch lines[row] {
        case .section(let section, let count): rows.section(section, count: count)
        case .group(let g, let count, let open):
            rows.group(g, count: count, open: open, off: g.key == nil ? nil : AddonGroups.isOff(g, items))
        case .item(let addon, let nested): rows.item(addon, nested: nested, width: tableView.bounds.width)
        case .problem(let addon): rows.problem(addon)
        }
    }
}
