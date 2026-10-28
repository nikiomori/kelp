import AppKit
import Core
import DesignKit
import KelpKit

/// What each running session costs, like Activity Monitor for agents: CPU (100% = one core) and memory summed over
/// everything under its terminal, busiest first, with Stop. Measured every two seconds while the panel shows.
@MainActor
final class ActivityController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    private struct Row {
        var session: Session
        var cpu: Double
        var memory: Int
        var processes: Int
    }
    private let table = NSTableView()
    private let total = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: String(localized: "No sessions running."))
    private var rows: [Row] = []

    override func loadView() {
        let col = NSTableColumn(identifier: .init("a")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = TextSize.of(40)
        table.dataSource = self
        table.delegate = self
        table.target = self; table.doubleAction = #selector(open)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        total.font = .uiDigits(11); total.textColor = .secondaryLabelColor
        empty.textColor = .secondaryLabelColor; empty.isHidden = true
        let v = NSView()
        for x in [total, scroll, empty] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            total.topAnchor.constraint(equalTo: v.topAnchor, constant: 10), total.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: total.bottomAnchor, constant: 6), scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: v.centerXAnchor), empty.topAnchor.constraint(equalTo: total.bottomAnchor, constant: 40)
        ])
        view = v
    }

    /// Watched while the panel shows: the daemon measures every two seconds and says when it changed.
    override func viewDidAppear() {
        super.viewDidAppear()
        watched.key = ""
        show(app.activity)
    }
    override func viewDidDisappear() { super.viewDidDisappear(); watched.key = nil }
    private lazy var watched = Watched(.activity, in: app)

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [app] in app.activity } changed: { [weak self] in self?.show($0) }
    }

    private func show(_ e: ActivityEvent?) {
        guard let e else { return }
        let m = app
        // Couldn't measure: say why where "No sessions running." would be, not that nothing runs.
        empty.stringValue = e.error.map { String(localized: "Couldn't measure the sessions: \($0)") } ?? String(localized: "No sessions running.")
        rows = (e.usage ?? []).compactMap { u in
            guard let s = m.session(u.session) else { return nil }
            return Row(session: s, cpu: u.cpu, memory: u.memory, processes: u.processes)
        }
        let cpu = rows.reduce(0) { $0 + $1.cpu }, mem = rows.reduce(0) { $0 + $1.memory }
        total.stringValue = rows.isEmpty ? "" : String(localized: "\(rows.count) sessions · CPU \(Self.percent(cpu)) · \(Self.bytes(mem))")
        empty.isHidden = !rows.isEmpty
        table.reloadData()
    }

    static func percent(_ cpu: Double) -> String { cpu < 10 ? String(format: "%.1f%%", cpu) : "\(Int(cpu.rounded()))%" }
    static func bytes(_ b: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let app = self.app
        let r = rows[row], s = r.session, m = app
        let icon = NSImageView(image: (s.agent == "shell" ? NSImage.symbol("terminal") : app.catalog.icon(s.agent)) ?? NSImage())
        let name = NSTextField(labelWithString: s.agent == "shell" ? (s.title.isEmpty ? String(localized: "Terminal") : s.title) : app.catalog.displayName(s))
        name.font = .ui(12, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let place = NSTextField(labelWithString: [m.worktree(s.worktreeId)?.displayName, String(localized: "\(r.processes) processes")]
            .compactMap { $0 }.joined(separator: " · "))
        place.font = .ui(11)
        place.textColor = .secondaryLabelColor
        place.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, place])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let cost = NSTextField(labelWithString: "\(Self.percent(r.cpu))\n\(Self.bytes(r.memory))")
        cost.font = .uiDigits(11)
        cost.alignment = .right
        cost.textColor = r.cpu > 80 ? .systemOrange : .secondaryLabelColor
        let stop = ClosureButton(title: "") { AgentActions(app).stop([s.id]) }
        stop.image = .symbol("stop.circle", String(localized: "Stop"))
        stop.isBordered = false
        stop.contentTintColor = .secondaryLabelColor
        stop.toolTip = String(localized: "Stop \(name.stringValue) (ends its processes)")
        for x in [name, place, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let rowView = NSStackView(views: [icon, text, NSView(), cost, stop]); rowView.spacing = 8
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return rowView
    }

    @objc private func open() {
        guard rows.indices.contains(table.clickedRow) else { return }
        app.workbench.focus(session: rows[table.clickedRow].session.id)
    }
}
