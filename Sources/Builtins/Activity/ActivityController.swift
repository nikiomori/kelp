import AppKit
import Core
import DesignKit
import KelpKit

/// What each running session costs, like Activity Monitor for agents: CPU (100% = one core) and memory summed over
/// everything under its terminal, busiest first, with Stop. Measured every two seconds while the panel shows.
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
        /// Drawn alike: the figures as the row writes them (a measure two seconds on mostly moves a digit no one sees).
        static func == (a: Row, b: Row) -> Bool {
            a.session == b.session && a.processes == b.processes && (a.cpu > 80) == (b.cpu > 80)
                && ActivityController.percent(a.cpu) == ActivityController.percent(b.cpu)
                && bytes(a.memory) == bytes(b.memory)
        }
    }
    private let table = NSTableView()
    private let total = NSTextField.label("", font: .uiDigits(TextSize.row), color: .secondaryLabelColor)
    private let empty = EmptyStateView()
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
        let header = Bar.panel([total])
        let root = stacked(header, scroll)
        empty.place(in: root, under: header)
        view = root
    }

    /// Watched while the panel shows: the daemon measures every two seconds and says when it changed.
    override func viewDidAppear() {
        super.viewDidAppear()
        watched.key = ""
        show(app.latest(ActivityEvent.self))
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        watched.key = nil
    }
    private lazy var watched = Watched(.activity, in: app)
    /// Measures pushed while a collapsed inspector hides it: the latest shows when it does.
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
        let model = app
        // Couldn't measure: say why where "No sessions running." would be, not that nothing runs.
        let was = rows
        rows = (event.usage ?? []).compactMap { usage in
            guard let session = model.session(usage.session) else { return nil }
            return Row(session: session, cpu: usage.cpu, memory: usage.memory, processes: usage.processes)
        }
        let cpu = rows.reduce(0) { $0 + $1.cpu }, mem = rows.reduce(0) { $0 + $1.memory }
        total.stringValue =
            rows.isEmpty
            ? "" : String(localized: "\(rows.count) sessions · CPU \(Self.percent(cpu)) · \(bytes(mem))")
        if let error = event.error {
            empty.showError(String(localized: "Couldn't measure the sessions"), text: error)
        } else {
            empty.show(
                rows.isEmpty ? String(localized: "No Sessions Running") : nil,
                symbol: "gauge.with.dots.needle.33percent")
        }
        // The same sessions in the same order: only the rows whose figures moved are drawn again.
        guard was.map(\.session.id) == rows.map(\.session.id) else { return table.reloadData() }
        let moved = IndexSet(rows.indices.filter { rows[$0] != was[$0] })
        table.reloadData(forRowIndexes: moved, columnIndexes: [0])
    }

    nonisolated static func percent(_ cpu: Double) -> String {
        cpu < 10 ? String(format: "%.1f%%", cpu) : "\(Int(cpu.rounded()))%"
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let app = self.app
        let entry = rows[row], session = entry.session, model = app
        let icon = NSImageView(
            image: (session.agent == "shell" ? NSImage.symbol("terminal") : app.catalog.icon(session.agent))
                ?? NSImage())
        let name = NSTextField(
            labelWithString: session.agent == "shell"
                ? (session.title.isEmpty ? String(localized: "Terminal") : session.title)
                : app.catalog.displayName(session))
        name.font = .ui(TextSize.row, weight: .medium)
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
        let stop = IconButton(.symbol("stop.circle"), tip: tip) { AgentActions(app).stop([session.id]) }
        for x in [name, place, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let rowView = NSStackView(views: [icon, text, NSView(), cost, stop])
        rowView.spacing = 8
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return rowView
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        AgentActions(app).addSessionItems(to: m, rows[table.clickedRow].session.id)
    }

    @objc private func open() {
        guard rows.indices.contains(table.clickedRow) else { return }
        app.workbench.focus(session: rows[table.clickedRow].session.id)
    }
}
