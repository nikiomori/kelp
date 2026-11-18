import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The panel that lists the pages agents made in the workspace on screen (`.kelp/artifacts`, which the daemon reads
/// while the panel shows). Pages are grouped by their last change under Today / Yesterday / Previous 7 Days / Earlier.
/// Each page gets one line with its kind, and a second line only when there's news (the agent is writing it, or a
/// review waits for answers). A page not opened yet is in bold, and pages with the same title share one row. When the
/// pointer rests on a row, a card shows the page. A file opens in a tab. A page on an agent's own service opens in the
/// user's browser, because that browser is signed in to the service and Kelp's tabs aren't.
@MainActor
final class ArtifactsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSSearchFieldDelegate
{
    enum Row {
        case heading(String)
        /// The latest page with a title, and the earlier pages with the same title.
        case item(ArtifactItem, earlier: [ArtifactItem])
    }
    private static let seenKey = "artifacts.seen"
    /// The filter field shows once the panel has more than this many pages.
    private static let filterFrom = 12

    let app: AppModel
    let table = KeyTable()
    private let search = NSSearchField()
    private lazy var filterBar = NSStackView(views: [search])
    private let empty = EmptyStateView()
    let loading = LoadingView(rows: true)
    private(set) var rows: [Row] = []
    private var count = 0
    private lazy var watched = Watched(.artifacts, in: app)
    private lazy var card = ArtifactCard(app: app)
    private var shown = false
    private lazy var whenShown = WhenShown(view)
    /// The path Quick Look shows (`quickLook`).
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
        filterBar.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        // There's no bar on top, because the inspector's title names the panel. The filter sits over the list it
        // filters, as every panel's does, so there is one place to look for a filter.
        let column = NSStackView(views: [filterBar, scroll])
        column.orientation = .vertical
        column.spacing = 0
        let content = NSView()
        content.pin(column)
        empty.place(in: content)
        loading.place(in: content)
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Follows the workspace on screen, its pages, and its chats (which tell who made each page, and whether that
        // chat is still writing it).
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
        // Until the first answer, an empty list would read as no pages: the wait says it is on its way.
        if shown, let wid = app.workbench.workspaceId, app.latest(ArtifactsEvent.self, wid) == nil {
            loading.wait(String(localized: "Reading the pages…"))
        } else {
            loading.show(nil)
        }
        reload()
    }
    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Rows

    /// Rebuilds the rows now while the panel is on screen. While it's hidden, it rebuilds once when it shows again.
    private func reload() { whenShown.run { [weak self] in self?.rebuild() } }

    private func rebuild() {
        let list = app.latest(ArtifactsEvent.self, app.workbench.workspaceId ?? "")?.items
        if list != nil, loading.showing {   // a wait on screen stays its moment, and then gives way to the answer
            Task {
                await loading.settled()
                loading.show(nil)
                rebuild()
            }
            return
        }
        if list != nil { loading.show(nil) }
        let items = list ?? []
        seedSeen(items)
        count = items.count
        let find = search.stringValue.trimmingCharacters(in: .whitespaces)
        let project = app.projectName(app.worktree(app.workbench.workspaceId)?.repoId)
        let found = items.filter { find.isEmpty || title($0, project).localizedCaseInsensitiveContains(find) }
        rows = Self.rows(found, title: { self.title($0, project) }, now: Date())
        filterBar.isHidden = count <= Self.filterFrom && find.isEmpty
        empty.show(
            list != nil && items.isEmpty ? String(localized: "No Artifacts Yet") : nil, symbol: "doc.richtext",
            text: String(localized: "Pages agents make show here."), buttons: [makeButton])
        table.reloadData()
        markOpen()
    }

    /// Returns the rows: headings by when each page last changed, and one row per title, holding the latest page with
    /// that title and the earlier ones (the list comes latest first).
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

    /// Returns the title without the project's name in front ("Kelp — review 232f2997" in Kelp becomes "Review
    /// 232f2997"), because the panel shows only one project's pages and the name took a third of the row.
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

    /// The Make… button. Its menu has the same choices as the start page and "+". A choice starts the default agent
    /// with the line typed in, for the user to finish.
    private lazy var makeButton = NSButton(title: String(localized: "Make…"), target: self, action: #selector(showMake))
    @objc private func showMake() {
        makeMenu(app).popUp(positioning: nil, at: NSPoint(x: 0, y: makeButton.bounds.height + 4), in: makeButton)
    }

    // MARK: Opened

    /// The pages that were opened from here or shown in a tab. The first time the panel lists pages, all of them count
    /// as seen already.
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

    /// Selects the row of the page the focused tab shows, so the tab and its row read as one. When the page opened in
    /// the browser, no row is selected.
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
    /// A day's heading does nothing on a click, so it doesn't light up under the pointer as the pages under it do.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let heading = item(at: row) == nil
        return ListRowView(lights: { _ in !heading })
    }
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

    /// Whether the agent is writing the page: it was saved in the last two minutes and its chat is working.
    func writing(_ item: ArtifactItem) -> Bool {
        guard let modified = item.modified, app.session(item.session ?? "")?.status == .working else { return false }
        return Date().timeIntervalSince1970 - modified < 120
    }

    /// The row's second line, only when there's something to say: the agent is writing the page, or how much of a
    /// review is answered.
    func note(_ item: ArtifactItem) -> (text: String, waits: Bool)? {
        if writing(item), let session = item.session.flatMap(app.session) {
            return (String(localized: "\(app.catalog.name(session.agent)) is writing"), false)
        }
        guard let points = item.points, points > 0 else { return nil }
        let answered = item.answered ?? 0
        return (String(localized: "\(answered) of \(points) answered"), answered < points)
    }

    /// Called when the pointer rests on a row (or leaves it). The page's card shows after a moment.
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
        guard let (item, _) = item(at: table.actedRow) else { return }
        openItem(item)
    }
    func openItem(_ item: ArtifactItem) {
        card.close()
        markSeen([item.target])
        // Only https opens, because the record may come from a cloned repository (`Artifacts.record` refuses any
        // other scheme too).
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
