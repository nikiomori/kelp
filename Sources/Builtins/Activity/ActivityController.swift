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
    private struct Row {
        var session: Session
        var cpu: Double
        var memory: Int
        var processes: Int
    }
    private let table = NSTableView()
    private let total = NSTextField(labelWithString: "")
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
        total.font = .uiDigits(TextSize.row)
        total.textColor = .secondaryLabelColor
        total.lineBreakMode = .byTruncatingTail
        total.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = Bar.panel([total])
        let root = NSView()
        for x in [header, scroll] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(x)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
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

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app] in
            app.latest(ActivityEvent.self)
        } changed: { [weak self] in
            self?.show($0)
        }
    }

    private func show(_ event: ActivityEvent?) {
        guard let event else { return }
        let model = app
        // Couldn't measure: say why where "No sessions running." would be, not that nothing runs.
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
                rows.isEmpty ? String(localized: "No sessions running") : nil,
                symbol: "gauge.with.dots.needle.33percent")
        }
        table.reloadData()
    }

    static func percent(_ cpu: Double) -> String { cpu < 10 ? String(format: "%.1f%%", cpu) : "\(Int(cpu.rounded()))%" }

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
