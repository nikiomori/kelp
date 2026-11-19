import AppKit
import Core
import DesignKit
import KelpKit

/// What each running session costs, like Activity Monitor for agents: CPU (100% = one core) and memory, summed over
/// every process under the session's terminal, busiest first, with Stop. It measures every two seconds while it shows.
@MainActor
final class ActivityController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    private struct Row: Equatable {
        var session: Session
        var cpu: Double
        var memory: Int
        var processes: Int
        /// Two rows are equal when they print the same figures. A new measure every two seconds mostly moves a digit
        /// no one sees, so such a row is not drawn again.
        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.session == rhs.session && lhs.processes == rhs.processes && (lhs.cpu > 80) == (rhs.cpu > 80)
                && ActivityController.percent(lhs.cpu) == ActivityController.percent(rhs.cpu)
                && bytes(lhs.memory) == bytes(rhs.memory)
        }
    }
    private let table = NSTableView()
    private let total = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    private let empty = EmptyStateView()
    /// Stands in the rows' place until the daemon's first measure comes, once that has taken a second.
    private let loading = LoadingView(rows: true)
    /// Says a measure failed over the rows the last one read, which stay under it.
    private lazy var failureBar = FailureBar { [weak self] in self?.app.watchAgain(.activity) }
    private var rows: [Row] = []

    override func loadView() {
        let scroll = table.plainList("a")
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open)
        table.menu = NSMenu()
        table.menu?.delegate = self
        let header = failureBar.under(Bar.panel([total]))
        let root = stacked(header, scroll)
        empty.place(in: root, under: header)
        loading.place(in: root, under: header)
        view = root
    }

    /// The panel watches activity only while it shows. The daemon measures every two seconds and says when it changed.
    override func viewDidAppear() {
        super.viewDidAppear()
        watched.key = ""
        if let event = app.latest(ActivityEvent.self) {
            show(event)
        } else {
            loading.wait(String(localized: "Measuring the sessions…"))
        }
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        watched.key = nil
    }
    private lazy var watched = Watched(.activity, in: app)
    /// Holds back measures pushed while a collapsed inspector hides the panel; the latest shows when the panel does.
    private lazy var whenShown = WhenShown(view)

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app] in
            app.latest(ActivityEvent.self)
        } changed: { [weak self] event in
            self?.whenShown.run { self?.show(event) }
        }
    }

    private func show(_ event: ActivityEvent?) {
        guard let event else { return }
        loading.show(nil)
        let model = app
        // A measure that failed keeps the rows the last one read, under a line that says why. With none to keep, the
        // empty state says why, in the place of "No sessions running.", rather than claiming nothing runs.
        let was = rows, places = table.rowPlaces(rowKey)
        let kept = event.error != nil && !was.isEmpty
        failureBar.show(kept ? event.error : nil)
        if !kept {
            let read: [Row] = (event.usage ?? []).compactMap { usage in
                guard let session = model.session(usage.session) else { return nil }
                return Row(session: session, cpu: usage.cpu, memory: usage.memory, processes: usage.processes)
            }
            rows = Self.holdingOrder(read, was: was)
        }
        let cpu = rows.reduce(0) { $0 + $1.cpu }, mem = rows.reduce(0) { $0 + $1.memory }
        total.stringValue =
            rows.isEmpty
            ? "" : String(localized: "\(rows.count) sessions · CPU \(Self.percent(cpu)) · \(bytes(mem))")
        if let error = event.error, rows.isEmpty {
            empty.showError(String(localized: "Couldn’t Measure the Sessions"), text: error)
        } else {
            empty.show(
                rows.isEmpty ? String(localized: "No Sessions Running") : nil,
                symbol: "gauge.with.dots.needle.33percent")
        }
        // When the sessions and their order are unchanged, only the rows whose figures moved are drawn again.
        // Otherwise a session that came or went fades, and the rest travel to their new lines.
        guard was.map(\.session.id) == rows.map(\.session.id) else {
            let old = Set(was.map(\.session.id)), now = Set(rows.map(\.session.id))
            return table.reloadSettling(
                from: places, came: now.subtracting(old), gone: old.subtracting(now), rowKey
            ) { table.reloadData() }
        }
        let moved = IndexSet(rows.indices.filter { rows[$0] != was[$0] })
        table.reloadData(forRowIndexes: moved, columnIndexes: [0])
    }
    private func rowKey(_ row: Int) -> String? { rows.indices.contains(row) ? rows[row].session.id : nil }

    /// The daemon's order, busiest first, except that rows showing the same CPU keep the order they had: two sessions
    /// near the same load would otherwise trade lines on every measure, under the pointer aiming at a Stop.
    private static func holdingOrder(_ rows: [Row], was: [Row]) -> [Row] {
        let before = Dictionary(was.enumerated().map { ($1.session.id, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ index: Int) -> (Double, Int, Int) {
            let cpu = rows[index].cpu, shown = cpu < 10 ? (cpu * 10).rounded() / 10 : cpu.rounded()   // as `percent`
            return (-shown, before[rows[index].session.id] ?? .max, index)
        }
        return rows.indices.sorted { key($0) < key($1) }.map { rows[$0] }
    }

    nonisolated static func percent(_ cpu: Double) -> String {
        cpu < 10 ? String(format: "%.1f%%", cpu) : "\(Int(cpu.rounded()))%"
    }

    func numberOfRows(in table: NSTableView) -> Int { rows.count }
    func tableView(_ table: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }

    func tableView(_ table: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = self.app
        let entry = rows[row], session = entry.session, model = app
        let icon = NSImageView(
            image: (session.isTerminal ? NSImage.symbol("terminal") : app.catalog.icon(session.agent))
                ?? NSImage())
        let name = NSTextField(
            labelWithString: session.isTerminal
                ? (session.title.isEmpty ? String(localized: "Terminal") : session.title)
                : app.catalog.displayName(session))
        name.font = .ui(TextSize.row)
        name.lineBreakMode = .byTruncatingTail
        let place = NSTextField(
            labelWithString: [
                model.worktree(session.worktreeId)?.displayName, String(localized: "\(entry.processes) processes")
            ]
            .compactMap { $0 }.joined(separator: " · "))
        place.font = .ui(TextSize.caption)
        place.textColor = .secondaryLabelColor
        place.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, place])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        let cost = NSTextField(labelWithString: "\(Self.percent(entry.cpu))\n\(bytes(entry.memory))")
        cost.font = .uiDigits(TextSize.caption)
        cost.alignment = .right
        cost.textColor = entry.cpu > 80 ? .textOrange : .secondaryLabelColor
        let tip = String(localized: "Stop \(name.stringValue) (ends its processes)")
        let stop = IconButton(.symbol("stop.fill"), tip: tip) { AgentActions(app).stop([session.id]) }
        for x in [name, place, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let cell = ActivityCell(views: [icon, text, NSView(), cost, stop])
        cell.spacing = Metrics.gapWide
        cell.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.insetTrailing)
        icon.widthAnchor.constraint(equalToConstant: Metrics.appIcon).isActive = true
        cell.stop = stop
        // A row drawn again every two seconds under a still pointer keeps its Stop showing.
        let under = table.rowView(atRow: row, makeIfNecessary: false).flatMap { view in
            view.window.map { view.bounds.contains(view.convert($0.mouseLocationOutsideOfEventStream, from: nil)) }
        }
        cell.setHover(under ?? false)
        return cell
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        AgentActions(app).addSessionItems(to: menu, rows[table.clickedRow].session.id)
    }

    @objc private func open() {
        guard rows.indices.contains(table.actedRow) else { return }
        app.workbench.focus(session: rows[table.actedRow].session.id)
    }
}

/// A session's row. Its Stop shows only under the pointer, as a row's actions do; the right-click menu has it too.
/// The button keeps its room while hidden, so the figures beside it don't move.
@MainActor
private final class ActivityCell: NSStackView, Hoverable {
    var stop: NSView? {
        didSet {
            detachesHiddenViews = false
            stop?.isHidden = true
        }
    }
    func setHover(_ on: Bool) {
        guard let stop, stop.isHidden == on else { return }
        if window != nil { crossfade() }   // as a row's actions fade; a cell made again under the pointer just shows
        stop.isHidden = !on
    }
}
