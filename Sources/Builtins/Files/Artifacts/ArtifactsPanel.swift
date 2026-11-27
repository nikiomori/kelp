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

    let app: AppModel
    let table = KeyTable()
    private let search = NSSearchField()
    private lazy var filterBar = NSStackView(views: [search])
    private let empty = EmptyStateView()
    let loading = LoadingView(rows: true, rowHeight: Metrics.row)
    /// The last read that worked, which stays on show when the next one fails.
    private var read: ArtifactsEvent?
    private(set) lazy var failureBar = FailureBar { [weak self] in self?.readAgain() }
    private lazy var tryAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in
        self?.readAgain()
    }
    private func readAgain() { if let wid = app.workbench.workspaceId { app.watchAgain(.artifacts, wid) } }
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
        table.registerForDraggedTypes([.fileURL])   // a file from Finder starts a page (`startFrom`)
        search.placeholderString = String(localized: "Filter")
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        search.delegate = self
        filterBar.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        // There's no bar on top, because the inspector's title names the panel. The filter sits over the list it
        // filters, as every panel's does, so there is one place to look for a filter.
        // Every project's pages, with room for pictures, are a click away at the foot (Artifacts Overview).
        let all = PointerButton.link(String(localized: "Show All Artifacts"), font: .ui(TextSize.caption)) {
            [weak self] in self?.app.workbench.open(OverviewTab.uri)
        }
        let foot = Bar.foot([all])
        let column = NSStackView(views: [failureBar, filterBar, scroll, foot])
        column.orientation = .vertical
        column.spacing = 0
        failureBar.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        foot.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
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
            app.latest(ArtifactsEvent.self, app.workbench.workspaceId ?? "")
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [app] in
            PageAgents.watched(app)
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
        let latest = app.latest(ArtifactsEvent.self, app.workbench.workspaceId ?? "")
        if latest != nil, loading.showing {   // a wait on screen stays its moment, and then gives way to the answer
            Task {
                await loading.settled()
                loading.show(nil)
                rebuild()
            }
            return
        }
        if latest != nil { loading.show(nil) }
        // A read that failed keeps the pages the last one brought for this folder, under a line that says why. With
        // none to keep, the reason takes the list's place.
        if let latest, latest.error == nil { read = latest }
        let kept = read?.worktree == app.workbench.workspaceId ? read : nil
        let failed = latest?.error
        failureBar.show(kept == nil ? nil : failed)
        let list = (failed == nil ? latest : kept)?.items
        let items = list ?? []
        seedSeen(items)
        count = items.count
        let find = search.stringValue.trimmingCharacters(in: .whitespaces)
        let project = app.projectName(app.worktree(app.workbench.workspaceId)?.repoId)
        let found = items.filter { find.isEmpty || words($0, project).localizedCaseInsensitiveContains(find) }
        // Rows move only within one workspace's list: another workspace's pages are a new list.
        let places = listed == app.workbench.workspaceId ? table.rowPlaces(rowKey) : [:]
        let old = Set(rows.indices.compactMap(rowKey))
        rows = Self.rows(found, title: { self.title($0, project) }, now: Date(), busy: PageAgents.busy(app))
        listed = app.workbench.workspaceId
        filterBar.isHidden = count == 0 && find.isEmpty
        if let failed, kept == nil {
            empty.showError(String(localized: "Couldn’t Read the Pages"), text: failed, buttons: [tryAgain])
        } else {
            empty.show(
                list != nil && items.isEmpty ? String(localized: "No Artifacts Yet") : nil, symbol: "doc.richtext",
                text: String(localized: "Pages agents make show here."), buttons: [makeButton])
        }
        // A page that came fades in, one that went fades out, and the rows below travel, a row whose second line came
        // or went too.
        let now = Set(rows.indices.compactMap(rowKey))
        table.reloadSettling(from: places, came: now.subtracting(old), gone: old.subtracting(now), rowKey) {
            table.reloadData()
        }
        markOpen()
    }
    /// The workspace whose pages the rows list.
    private var listed: String?
    private func rowKey(_ row: Int) -> String? {
        guard rows.indices.contains(row) else { return nil }
        return switch rows[row] {
        case .heading(let text): "h:" + text
        case .item(let item, _): "i:" + item.target
        }
    }

    /// Returns the rows: the pages agents work with now (`busy`) under Now, then headings by when each page last
    /// changed, and one row per title, holding the latest page with that title and the earlier ones (the list comes
    /// latest first).
    nonisolated static func rows(
        _ items: [ArtifactItem], title: (ArtifactItem) -> String, now: Date, busy: Set<String> = []
    ) -> [Row] {
        var order: [String] = [], groups: [String: [ArtifactItem]] = [:]
        for item in items {
            let key = title(item).lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        let working = { (key: String) in groups[key]?.first.map { busy.contains($0.target) } == true }
        order = order.filter(working) + order.filter { !working($0) }
        var rows: [Row] = [], heading: String?
        for key in order {
            guard let group = groups[key], let latest = group.first else { continue }
            let section =
                working(key) ? String(localized: "Now") : Self.section(latest.modified ?? latest.created, now: now)
            if section != heading {
                rows.append(.heading(section))
                heading = section
            }
            rows.append(.item(latest, earlier: Array(group.dropFirst())))
        }
        return rows
    }

    nonisolated static func section(_ time: Double, now: Date, calendar: Calendar = .current) -> String {
        DaySections.title(time, now: now, calendar: calendar)
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

    /// The pages that were opened from here or shown in a tab (`ArtifactSeen`). The first time the panel lists pages,
    /// all of them count as seen already.
    private func seedSeen(_ items: [ArtifactItem]) {
        guard !ArtifactSeen.started(app), !items.isEmpty else { return }
        markSeen(items.map(\.target))
    }
    func isNew(_ item: ArtifactItem) -> Bool { ArtifactSeen.isNew(item, app) }
    private func markSeen(_ targets: [String]) {
        Task {
            guard await ArtifactSeen.mark(targets, app) else { return }
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

    func writing(_ item: ArtifactItem) -> Bool { ArtifactActions.writing(item, app) }
    func note(_ item: ArtifactItem) -> (text: String, waits: Bool)? { ArtifactActions.note(item, app) }

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
        ArtifactActions.open(app, item)
        if item.url != nil { markOpen() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let (item, earlier) = item(at: table.clickedRow) else { return }
        ArtifactActions.addItems(
            to: menu, app, item, open: { [weak self] in self?.openItem($0) },
            quickLook: { [weak self] in self?.quickLook(item) }, earlier: earlier)
    }
}
