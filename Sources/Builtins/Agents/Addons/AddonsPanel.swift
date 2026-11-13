import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// Skills & MCP: what the chat looked at last in the workspace on screen gets besides the prompt (its skills, MCP
/// servers and instruction files, as it reported them at its start), or what a new chat there would get when it has no
/// record. Read when the panel shows, and again when the workspace or the chat changes. A switch is the project's:
/// chats started from then on follow it, and the one on screen can be restarted to. A row opens its file.
@MainActor
final class AddonsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    let app: AppModel
    let table = AddonTable()
    private let empty = EmptyStateView()
    private let face = NSImageView()
    private let chatTitle = NSTextField(labelWithString: "")
    private let weight = NSHostingView(rootView: AddonWeight(headline: "", shares: []))
    private let filter = NSSearchField()
    private lazy var filterBar = NSStackView(views: [filter])
    lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in
        self?.showMore()
    }
    lazy var add = IconButton(.symbol("plus"), tip: String(localized: "Add")) { [weak self] in self?.showAdd() }
    private(set) var addons: Addons?
    private var lines: [AddonLine] = []
    /// The groups folded or unfolded by hand: view state, not kept. While filtering, a set of its own that starts empty
    /// with each new text (every group with a match open).
    private var toggled: Set<AddonGroup> = []
    private var toggledFiltering: Set<AddonGroup> = []
    private var shown = false
    private var loading: Task<Void, Never>?
    private let foot = NSStackView()
    private var laidOut: CGFloat = 0
    private let footNote = NSTextField(labelWithString: "")
    private(set) var shownChat: Session?
    /// The order, and whether what's off shows: this Mac's view of the list.
    var display: AddonView = AddonsPanel.savedView() { didSet { relist() } }

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
        table.doubleAction = #selector(openClicked)
        table.onReturn = { [weak self] in self.map { $0.open(row: $0.table.selectedRow) } }
        table.menu = NSMenu()
        table.menu?.delegate = self
        // The inspector's own title names the panel: its bar names the chat, as Source Control's names the branch.
        let header = Bar.panel([face, chatTitle], [add, more])
        chatTitle.font = .ui(TextSize.row, weight: .medium)
        chatTitle.lineBreakMode = .byTruncatingTail
        chatTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filter.placeholderString = String(localized: "Filter")
        filter.controlSize = .small
        filter.font = .ui(TextSize.caption)
        filter.sendsSearchStringImmediately = true
        filter.delegate = self
        filterBar.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        // Stacked: the filter and the summary take no room while they're hidden.
        filterBar.isHidden = true
        weight.sizingOptions = [.intrinsicContentSize]
        weight.isHidden = true
        let column = NSStackView(views: [header, filterBar, weight, scroll, makeFoot()])
        column.orientation = .vertical
        column.spacing = 0
        for part in column.arrangedSubviews { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let root = NSView()
        root.pin(column)
        empty.place(in: root, under: header)
        view = root
    }

    private func makeFoot() -> NSView {
        footNote.font = .ui(TextSize.caption)
        footNote.textColor = .secondaryLabelColor
        footNote.lineBreakMode = .byTruncatingTail
        footNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let restart = PointerButton(title: String(localized: "Restart This Chat")) { [weak self] in self?.restart() }
        foot.setViews([footNote, NSView(), restart], in: .leading)
        foot.spacing = Metrics.gap
        foot.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        foot.isHidden = true
        return foot
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [weak self] in
            // A Tidy Up chat starting, working and stopping turns its line into Show Chat, then its result.
            [
                self?.app.workbench.workspaceId, self?.chat?.id,
                self.flatMap { TidyUp.chat($0.app, $0.app.workbench.workspaceId ?? "") }.map {
                    $0.id + $0.status.rawValue
                }
            ]
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

    func reload() {
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
        let items = value?.items ?? [], known = value?.chat == true
        weight.isHidden = items.isEmpty || error != nil
        filterBar.isHidden = weight.isHidden
        weight.rootView = AddonWeight(
            headline: AddonGroups.headline(items, chat: known), shares: known ? AddonGroups.weight(items) : [])
        // The chat when the list is its own record (or nothing came back), else what a new one would get.
        let named = value.map { $0.chat ? chat : nil } ?? chat
        face.image = named.flatMap { app.catalog.icon($0.agent, size: Metrics.appIcon) }
        face.isHidden = face.image == nil
        chatTitle.stringValue =
            named.map(app.catalog.displayName) ?? (value == nil ? "" : String(localized: "What a new chat gets"))
        // Something waits for a restart, and there's a chat to restart.
        shownChat = known ? chat : nil
        let gone = value?.gone ?? []
        foot.isHidden = shownChat == nil || (gone.isEmpty && !items.contains(where: AddonGroups.waits))
        footNote.stringValue = AddonGroups.footNote(gone: gone)
        footNote.toolTip = gone.isEmpty ? nil : gone.joined(separator: "\n")
        relist()
    }

    /// The lines again, the selected one kept selected while it's still there.
    private func relist() {
        let selected = lines.indices.contains(table.selectedRow) ? lines[table.selectedRow] : nil
        let filtering = !display.filter.isEmpty
        lines = AddonGroups.lines(
            addons?.items ?? [], toggled: filtering ? toggledFiltering : toggled, view: display,
            tidied: addons?.tidied)
        table.reloadData()
        if let selected, let row = lines.firstIndex(of: selected) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    func controlTextDidChange(_ note: Notification) {
        toggledFiltering = []
        display.filter = filter.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// The project's switches, one after another, then the list again: the daemon says what they are now.
    func flip(_ keys: [String], on: Bool) {
        guard let workspace = app.workbench.workspaceId else { return }
        AddonMenu(app: app, worktreeId: workspace, items: [], chat: nil) { [weak self] in self?.reload() }
            .set(keys, on: on)
    }

    func restart() {
        guard let chat = shownChat else { return }
        AgentActions(app).restart(chat.id)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let workspace = app.workbench.workspaceId, lines.indices.contains(table.clickedRow) else { return }
        AddonMenu(app: app, worktreeId: workspace, items: addons?.items ?? [], chat: shownChat) { [weak self] in
            self?.reload()
        }
        .fill(menu, lines[table.clickedRow])
    }

    @objc private func clicked() {
        guard lines.indices.contains(table.clickedRow), case .group(let g, let count, _, _) = lines[table.clickedRow],
            count > 0
        else { return }
        let filtering = !display.filter.isEmpty
        if filtering {
            if toggledFiltering.remove(g) == nil { toggledFiltering.insert(g) }
        } else if toggled.remove(g) == nil {
            toggled.insert(g)
        }
        relist()
    }

    /// A double click: the row's file in a tab.
    @objc private func openClicked() { open(row: table.clickedRow) }

    /// Return, or a double click: the row's file in a tab.
    private func open(row: Int) {
        guard lines.indices.contains(row) else { return }
        switch lines[row] {
        case .item(let addon, _), .problem(let addon): if let path = addon.path { open(path) }
        default: break
        }
    }

    func open(_ path: String) { app.workbench.open(TabURI.file(path)) }

    // MARK: Table view

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch lines[row] {
        case .item, .problem: true
        case .section, .group, .unsigned, .instructions: false
        }
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch lines[row] {
        case .section: TextSize.of(Metrics.rowSection)
        case .instructions(_, .some) where TidyUp.working(app, app.workbench.workspaceId ?? "") == nil:
            TextSize.of(Metrics.rowTwoLine) + TextSize.of(Metrics.row)   // its buttons on a line of their own
        case .problem, .unsigned, .instructions: TextSize.of(Metrics.rowTwoLine)
        case .group, .item: TextSize.of(Metrics.row)
        }
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        var rows = AddonRows(app: app) { [weak self] key, on in self?.flip([key], on: on) }
        rows.onOpen = { [weak self] path in self?.open(path) }
        rows.onOff = { [weak self] keys in self?.flip(keys, on: false) }
        let items = addons?.items ?? []
        let workspace = app.workbench.workspaceId ?? ""
        let tidy = TidyUp(app: app, worktreeId: workspace, items: items)
        rows.onTidy = { tidy.run() }
        rows.onReview = { tidy.review() }
        rows.onUndo = { [weak self] in Task { await tidy.undo { self?.reload() } } }
        return switch lines[row] {
        case .section(let section, let count): rows.section(section, count: count)
        case .group(let g, let count, let tokens, let open):
            rows.group(
                g, count: count, tokens: tokens, open: open, off: g.key == nil ? nil : AddonGroups.isOff(g, items))
        case .item(let addon, let depth): rows.item(addon, depth: depth, width: tableView.bounds.width)
        case .problem(let addon): rows.problem(addon)
        case .unsigned(let servers): rows.unsigned(servers)
        case .instructions(let files, let tidied):
            rows.instructions(files, tidied: tidied, working: TidyUp.working(app, workspace) != nil)
        }
    }
}

/// The list: Return opens the selected row's file, as a double click does.
@MainActor
final class AddonTable: NSTableView {
    var onReturn: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\r" { onReturn() } else { super.keyDown(with: event) }
    }
}
