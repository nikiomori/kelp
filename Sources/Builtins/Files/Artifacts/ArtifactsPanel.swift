import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The pages agents made in the workspace on screen (`.kelp/artifacts`, read by the daemon while the panel shows), by
/// their last change under Today / Yesterday / Previous 7 Days / Earlier: one line each, what kind it is, a second line
/// only when there's news (its agent is writing it, a review waits for answers). One not opened yet is in bold; pages
/// of one title are one row. The pointer resting on a row shows the page in a card. A file opens in a tab; a page on an
/// agent's own service in the user's browser, which is signed in to it (Kelp's tabs aren't).
@MainActor
final class ArtifactsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    enum Row {
        case heading(String)
        /// The latest of its title, and the earlier ones under it.
        case item(ArtifactItem, earlier: [ArtifactItem])
    }
    private static let seenKey = "artifacts.seen"
    /// The filter shows from this many pages on.
    private static let filterFrom = 12

    let app: AppModel
    let table = ArtifactTable()
    private let search = NSSearchField()
    private lazy var foot = NSStackView(views: [search])
    private let empty = EmptyStateView()
    private(set) var rows: [Row] = []
    private var count = 0
    private lazy var watched = Watched(.artifacts, in: app)
    private lazy var card = ArtifactCard(app: app)
    private var shown = false
    private lazy var whenShown = WhenShown(view)
    /// What Quick Look shows (`quickLook`).
    var looked: String?

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = table.plainList("a")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(open)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.onSpace = { [weak self] in self?.togglePreview() }
        search.placeholderString = String(localized: "Filter")
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        search.delegate = self
        foot.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        // No bar on top: the inspector's title names it. The filter is at the foot, as in Xcode's navigators.
        let column = NSStackView(views: [scroll, foot])
        column.orientation = .vertical
        column.spacing = 0
        let content = NSView()
        content.pin(column)
        empty.place(in: content)
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The workspace on screen, its pages, and its chats: who made each page, and whether it's still writing.
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] _ in
            self?.watchShown()
        }
        track(owner: self) { [app] in
            app.latest(ArtifactsEvent.self, app.workbench.workspaceId ?? "")?.items
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [app] in
            app.sessions.map { "\($0.id)\($0.status)" }
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [app] in
            app.workbench.focusedTab
        } changed: { [weak self] _ in
            self?.markOpen()
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
        card.close()
        watchShown()
    }
    private func watchShown() {
        watched.key = shown ? app.workbench.workspaceId : nil
        reload()
    }
    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Rows

    /// Rebuilt while on screen; hidden, once when it shows again.
    private func reload() { whenShown.run { [weak self] in self?.rebuild() } }

    private func rebuild() {
        let list = app.latest(ArtifactsEvent.self, app.workbench.workspaceId ?? "")?.items
        let items = list ?? []
        seedSeen(items)
        count = items.count
        let find = search.stringValue.trimmingCharacters(in: .whitespaces)
        let project = app.projectName(app.worktree(app.workbench.workspaceId)?.repoId)
        let found = items.filter { find.isEmpty || title($0, project).localizedCaseInsensitiveContains(find) }
        rows = Self.rows(found, title: { self.title($0, project) }, now: Date())
        foot.isHidden = count <= Self.filterFrom && find.isEmpty
        empty.show(
            list != nil && items.isEmpty ? String(localized: "No Artifacts Yet") : nil, symbol: "doc.richtext",
            text: String(localized: "Pages agents make show here."), buttons: [makeButton])
        table.reloadData()
        markOpen()
    }

    /// Headings by when each page last changed; pages of one title folded into the latest (the list is latest first).
    nonisolated static func rows(_ items: [ArtifactItem], title: (ArtifactItem) -> String, now: Date) -> [Row] {
        var order: [String] = [], groups: [String: [ArtifactItem]] = [:]
        for item in items {
            let key = title(item).lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        var rows: [Row] = [], heading: String?
        for key in order {
            guard let group = groups[key], let latest = group.first else { continue }
            let section = Self.section(latest.modified ?? latest.created, now: now)
            if section != heading {
                rows.append(.heading(section))
                heading = section
            }
            rows.append(.item(latest, earlier: Array(group.dropFirst())))
        }
        return rows
    }

    nonisolated static func section(_ time: Double, now: Date, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: time), today = calendar.startOfDay(for: now)
        if date >= today { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday {
            return String(localized: "Yesterday")
        }
        if let week = calendar.date(byAdding: .day, value: -7, to: today), date >= week {
            return String(localized: "Previous 7 Days")
        }
        return String(localized: "Earlier")
    }

    /// The title without the project's name in front ("Kelp — review 232f2997" in Kelp: "Review 232f2997"): the panel
    /// shows one project's pages already, and the name took a third of the row.
    nonisolated static func shortTitle(_ title: String, project: String?) -> String {
        guard let project, !project.isEmpty, title.lowercased().hasPrefix(project.lowercased()) else { return title }
        let rest = title.dropFirst(project.count).drop { $0 == " " }
        guard let mark = rest.first, "—–-:|·".contains(mark) else { return title }
        let after = rest.dropFirst().drop { $0 == " " }
        return after.isEmpty ? title : after.prefix(1).uppercased() + after.dropFirst()
    }
    func title(_ item: ArtifactItem, _ project: String?) -> String { Self.shortTitle(item.title, project: project) }

    func item(at row: Int) -> (ArtifactItem, earlier: [ArtifactItem])? {
        guard rows.indices.contains(row), case .item(let item, let earlier) = rows[row] else { return nil }
        return (item, earlier)
    }

    /// Make's choices, as on the start page and in "+": the default agent starts with the line, for the user to finish.
    private lazy var makeButton = NSButton(title: String(localized: "Make…"), target: self, action: #selector(showMake))
    @objc private func showMake() {
        makeMenu(app).popUp(positioning: nil, at: NSPoint(x: 0, y: makeButton.bounds.height + 4), in: makeButton)
    }

    // MARK: Opened

    /// Pages opened from here or shown in a tab; the first time the panel lists any, those count as seen already.
    private var seen: Set<String> { Set(app.uiState.strings(Self.seenKey)) }
    private func seedSeen(_ items: [ArtifactItem]) {
        guard app.uiState[Self.seenKey] == nil, !items.isEmpty else { return }
        markSeen(items.map(\.target))
    }
    func isNew(_ item: ArtifactItem) -> Bool { app.uiState[Self.seenKey] != nil && !seen.contains(item.target) }
    private func markSeen(_ targets: [String]) {
        var list = app.uiState.strings(Self.seenKey)
        let added = targets.filter { !list.contains($0) }
        guard !added.isEmpty || app.uiState[Self.seenKey] == nil else { return }
        list = Array((list + added).suffix(500))
        let app = self.app
        Task {
            _ = await app.uiState.save(Self.seenKey, .array(list.map { .string($0) }))
            self.table.reloadData()
            self.markOpen()
        }
    }

    /// The page the focused tab shows is the row picked: the tab and its row read as one. A page that opened in the
    /// browser leaves nothing picked.
    private func markOpen() {
        let uri = app.workbench.focusedTab ?? ""
        let path = uri.hasPrefix("file://") ? TabURI.filePath(uri).path : nil
        let index = rows.firstIndex { row in
            guard case .item(let item, _) = row, let path else { return false }
            return item.url == nil && item.target == path
        }
        if let index, let (item, _) = self.item(at: index) {
            if table.selectedRow != index { table.selectRowIndexes([index], byExtendingSelection: false) }
            if isNew(item) { markSeen([item.target]) }
        } else if table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { item(at: row) != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let (item, _) = item(at: row) else { return TextSize.of(Metrics.rowSection) }
        return TextSize.of(note(item) == nil ? Metrics.row : Metrics.rowTwoLine)
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cells = ArtifactCells(panel: self)
        switch rows[row] {
        case .heading(let text): return cells.heading(text)
        case .item(let item, let earlier): return cells.item(item, earlier: earlier.count)
        }
    }

    /// Saved in the last two minutes while its chat works: the agent is writing it.
    func writing(_ item: ArtifactItem) -> Bool {
        guard let modified = item.modified, app.session(item.session ?? "")?.status == .working else { return false }
        return Date().timeIntervalSince1970 - modified < 120
    }

    /// The second line, only when it says something: its agent is writing it, or how far a review is answered.
    func note(_ item: ArtifactItem) -> (text: String, waits: Bool)? {
        if writing(item), let session = item.session.flatMap(app.session) {
            return (String(localized: "\(app.catalog.name(session.agent)) is writing"), false)
        }
        guard let points = item.points, points > 0 else { return nil }
        let answered = item.answered ?? 0
        return (String(localized: "\(answered) of \(points) answered"), answered < points)
    }

    /// The pointer rests on a row (or left it): its card after a moment.
    func hover(_ item: ArtifactItem?, over cell: NSView) {
        guard let item else {
            card.hover(nil, rect: .zero, in: table)
            return
        }
        let project = app.projectName(app.worktree(app.workbench.workspaceId)?.repoId)
        let row = table.row(for: cell)
        let rect = row >= 0 ? table.rect(ofRow: row) : cell.frame
        card.hover(ArtifactCard.Shown(item: item, title: title(item, project)), rect: rect, in: table)
    }

    // MARK: Actions

    @objc private func open() {
        guard let (item, _) = item(at: table.clickedRow) else { return }
        openItem(item)
    }
    func openItem(_ item: ArtifactItem) {
        card.close()
        markSeen([item.target])
        // Only a web page: the record may be a cloned repository's (`Artifacts.record` refuses any other scheme too).
        if item.url != nil {
            if let url = URL(string: item.target), url.scheme == "https" { PreviewLinks.openOutside(url) }
            markOpen()
        } else {
            app.workbench.open(item.target)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let (item, earlier) = item(at: table.clickedRow) else { return }
        let app = self.app
        menu.add(String(localized: "Open")) { [weak self] in self?.openItem(item) }
        if item.preview != nil {
            menu.add(String(localized: "Quick Look")) { [weak self] in self?.quickLook(item) }
        }
        if !earlier.isEmpty {
            let versions = NSMenu()
            for old in earlier {
                let when = Date(timeIntervalSince1970: old.modified ?? old.created)
                versions.add(when.formatted(date: .abbreviated, time: .shortened)) { [weak self] in
                    self?.openItem(old)
                }
            }
            menu.addItem(withTitle: String(localized: "Earlier Versions"), action: nil, keyEquivalent: "").submenu =
                versions
        }
        if let session = item.session.flatMap(app.session), session.status != .exited {
            menu.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: session.id) }
        }
        menu.addItem(.separator())
        if let link = item.url {
            menu.add(String(localized: "Copy Link")) {
                copyText(link)
            }
        } else {
            menu.add(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.target)])
            }
        }
    }
}

/// The list: Space shows the picked page in Quick Look.
final class ArtifactTable: NSTableView {
    var onSpace: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
            onSpace()
        } else {
            super.keyDown(with: event)
        }
    }
}
