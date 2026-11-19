import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

/// The Skills & MCP panel. It lists what the chat looked at last in the workspace on screen gets besides the prompt:
/// its skills, MCP servers and instruction files, as the chat reported them when it started. When the chat has no such
/// record, the panel lists what a new chat there would get. The list is read when the panel shows, and again when the
/// workspace or the chat changes (`+Loading` shows the read in progress). In a chat's own list, what only other agents
/// get sits in a section of its own. Each switch belongs to the project, so chats started after a flip follow it, and
/// the chat on screen can be restarted to follow it too. Double-clicking a row opens its file.
@MainActor
final class AddonsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    let app: AppModel
    let table = KeyTable()
    let empty = EmptyStateView()
    let loadingView = LoadingView(rows: true)
    let face = AddonFace()
    private let chatTitle = NSTextField(labelWithString: "")
    let weight = NSHostingView(rootView: AddonWeight(headline: "", shares: []))
    private(set) lazy var failureBar = FailureBar { [weak self] in self?.reload() }
    private let filter = NSSearchField()
    private lazy var filterBar = NSStackView(views: [filter])
    lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More Actions")) { [weak self] in
        self?.showMore()
    }
    lazy var add = IconButton(.symbol("plus"), tip: String(localized: "Add")) { [weak self] in self?.showAdd() }
    private(set) var addons: Addons?
    private(set) var lines: [AddonLine] = []
    /// The groups the person folded or unfolded by hand. This is view state and isn't saved. While filtering, a
    /// separate set is used that starts empty with each new filter text, so every group with a match starts open.
    private var toggled: Set<AddonGroup> = []
    private var toggledFiltering: Set<AddonGroup> = []
    private var shown = false
    private var loading: Task<Void, Never>?
    var busy: Task<Void, Never>?
    var busySince: Date?
    /// The workspace and chat the list on screen was read for.
    private var shownKey: String?
    /// The agent of the chat whose own list is on screen. Items that only other agents get sit in a section of their
    /// own.
    private var listAgent: String?
    /// The switches that were flipped and not answered yet, with the state asked for.
    private var pending: [String: Bool] = [:]
    private let foot = NSStackView()
    private var laidOut: CGFloat = 0
    private let resized = Debounce()
    private let footNote = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private(set) var shownChat: Session?
    /// The order of the list, and whether items that are off show. This view setting belongs to this Mac.
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
        // The inspector's own title already names the panel, so this bar names the chat, the way the bar of Source
        // Control names the branch.
        let header = Bar.panel([face, chatTitle], [add, more])
        chatTitle.font = .ui(TextSize.row)   // as Source Control's bar names its branch
        chatTitle.lineBreakMode = .byTruncatingTail
        chatTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filter.placeholderString = String(localized: "Filter")
        filter.controlSize = .small
        filter.font = .ui(TextSize.caption)
        filter.sendsSearchStringImmediately = true
        filter.delegate = self
        filterBar.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        // The filter and the summary sit in a stack view, so they take no room while they are hidden.
        filterBar.isHidden = true
        weight.sizingOptions = [.intrinsicContentSize]
        weight.isHidden = true
        let column = NSStackView(views: [header, failureBar, filterBar, weight, scroll, makeFoot()])
        column.orientation = .vertical
        column.spacing = 0
        for part in column.arrangedSubviews { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let root = NSView()
        root.pin(column)
        empty.place(in: root, under: header)
        loadingView.place(in: root, under: header)
        view = root
    }

    private func makeFoot() -> NSView {
        // A worded button in a bottom bar is the system's small one: words alone don't read as a button.
        let restart = ClosureButton(title: String(localized: "Restart This Chat")) { [weak self] in self?.restart() }
        restart.bezelStyle = .push
        restart.controlSize = .small
        foot.setViews([footNote, NSView(), restart], in: .leading)
        foot.spacing = Metrics.gap
        foot.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        foot.isHidden = true
        return foot
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [weak self] in
            // When a Tidy Up chat starts, works and stops, the panel reloads, so the Instructions row turns into Show
            // Chat and then into the result.
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
    /// Rows lay themselves out for the panel's width, so they are drawn again when the width changes. While the
    /// inspector's edge is dragged, the redraw waits until the drag rests, because each step of the drag used to build
    /// every row again.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard abs(table.bounds.width - laidOut) >= 1 else { return }
        if laidOut == 0 { return relayout() }
        resized.after(0.1) { [weak self] in self?.relayout() }
    }
    private func relayout() {
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
        endBusy()
    }

    /// The agent chat looked at last in the workspace on screen (the focused tab, when that is an agent chat). Else
    /// the workspace's newest agent chat that hasn't exited.
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
        guard let workspace = app.workbench.workspaceId else { return show(nil, error: nil, chat: nil, key: nil) }
        let chat = chat
        let key = workspace + "/" + (chat?.id ?? "")
        // The bar names the chat at once, and only the list waits for the daemon.
        if key != shownKey { name(chat, newChat: true) }
        beginBusy(stale: key != shownKey)
        loading = Task { [weak self, app] in
            let answer = await app.tryCall(AddonsList(worktreeId: workspace, session: chat?.id))
            guard !Task.isCancelled else { return }
            await self?.settle()
            guard !Task.isCancelled else { return }
            self?.show(answer.value, error: answer.error, chat: chat, key: key)
        }
    }

    /// Sets the bar to the chat's agent icon and name. With no chat, the bar says what a new chat gets when `newChat`
    /// is true, and nothing otherwise.
    private func name(_ chat: Session?, newChat: Bool) {
        face.image = chat.flatMap { app.catalog.icon($0.agent, size: Metrics.appIcon) }
        chatTitle.stringValue =
            chat.map(app.catalog.displayName) ?? (newChat ? String(localized: "What a new chat gets") : "")
    }

    /// Shows the answer for `key`. When reading the same list again fails, the old list stays under a line that says
    /// so. Another chat's list crossfades in, and in a new answer for the same chat a few rows that came or went move
    /// the others.
    private func show(_ value: Addons?, error: String?, chat: Session?, key: String?) {
        endBusy()
        pending = [:]
        let same = key == shownKey && addons != nil
        if let error, same {
            failureBar.show(error)
            return relist()
        }
        failureBar.show(nil)
        if !same, addons != nil { table.enclosingScrollView?.crossfade(Motion.appear) }
        let places = same ? table.rowPlaces(lineKey) : [:]
        shownKey = key
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
            headline: AddonGroups.headline(items, chat: known), shares: known ? AddonGroups.weight(items) : [],
            when: known ? chat.map { AddonGroups.loaded($0.createdAt) } : nil)
        // The bar names the chat when the list is that chat's own record (or nothing came back), else it names what a
        // new chat would get.
        let named = value.map { $0.chat ? chat : nil } ?? chat
        name(named, newChat: value != nil)
        listAgent = known ? chat?.agent : nil
        // The foot shows when something waits for a restart and there is a chat to restart.
        shownChat = known ? chat : nil
        let gone = value?.gone ?? []
        let behind = items.contains { AddonGroups.behind($0) != nil }
        foot.isHidden = shownChat == nil || (gone.isEmpty && !behind && !items.contains(where: AddonGroups.waits))
        footNote.stringValue = AddonGroups.footNote(gone: gone)
        footNote.toolTip = gone.isEmpty ? nil : gone.joined(separator: "\n")
        relist(settling: places)
    }

    /// Rebuilds the lines, and keeps the selected line selected while it is still there. With `places` (where the
    /// rows stood before), a few rows that came or went move the others instead of jumping them.
    private func relist(settling places: [String: NSPoint] = [:]) {
        let selected = lines.indices.contains(table.selectedRow) ? lines[table.selectedRow] : nil
        let filtering = !display.filter.isEmpty, old = Set(lines.map(\.key))
        lines = AddonGroups.lines(
            addons?.items ?? [], toggled: filtering ? toggledFiltering : toggled, view: display,
            tidied: addons?.tidied, agent: listAgent)
        let now = Set(lines.map(\.key))
        table.reloadSettling(from: places, came: now.subtracting(old), gone: old.subtracting(now), lineKey) {
            table.reloadData()
            if let selected, let row = lines.firstIndex(of: selected) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    /// A line's name across a reload, for `relist(settling:)`.
    func lineKey(_ row: Int) -> String? { lines.indices.contains(row) ? lines[row].key : nil }

    func controlTextDidChange(_ note: Notification) {
        toggledFiltering = []
        display.filter = filter.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// Sets the project's switches one after another, then reads the list again, because the daemon says what they
    /// are now.
    func flip(_ keys: [String], on: Bool) {
        guard let workspace = app.workbench.workspaceId else { return }
        for key in keys { pending[key] = on }
        relist()
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

    /// A double click opens the row's file in a tab.
    @objc private func openClicked() { open(row: table.clickedRow) }

    /// Opens the row's file in a tab, on Return or a double click.
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
    /// A section's title does nothing on a click, so it doesn't light up under the pointer. A group's row folds, so it
    /// lights as the items do.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard case .section = lines[row] else { return ListRowView() }
        return ListRowView(lights: { _ in false })
    }
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
            TextSize.of(Metrics.rowTwoLine) + TextSize.of(Metrics.row)   // the row's buttons get a line of their own
        case .problem, .unsigned, .instructions: TextSize.of(Metrics.rowTwoLine)
        case .group, .item: TextSize.of(Metrics.row)
        }
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        var rows = AddonRows(app: app) { [weak self] key, on in self?.flip([key], on: on) }
        rows.agent = listAgent
        rows.pending = pending
        rows.onOpen = { [weak self] path in self?.open(path) }
        rows.onOff = { [weak self] keys in self?.flip(keys, on: false) }
        let items = addons?.items ?? []
        let workspace = app.workbench.workspaceId ?? ""
        let tidy = TidyUp(app: app, worktreeId: workspace, items: items)
        rows.onTidy = { tidy.run() }
        rows.onReview = { tidy.review() }
        rows.onUndo = { [weak self] in Task { await tidy.undo { self?.reload() } } }
        rows.onKeep = { [weak self] in Task { await tidy.keep { self?.reload() } } }
        return switch lines[row] {
        case .section(let section, let count): rows.section(section, count: count)
        case .group(let g, let count, let tokens, let open):
            rows.group(
                g, count: count, tokens: tokens, open: open, off: g.key == nil ? nil : AddonGroups.isOff(g, items))
        case .item(let addon, let depth):
            rows.item(
                addon, depth: depth, width: tableView.bounds.width, parent: AddonGroups.parent(of: row, in: lines))
        case .problem(let addon): rows.problem(addon)
        case .unsigned(let servers): rows.unsigned(servers)
        case .instructions(let files, let tidied):
            rows.instructions(files, tidied: tidied, working: TidyUp.working(app, workspace) != nil)
        }
    }
}
