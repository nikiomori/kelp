import AppKit
import Core
import DesignKit
import KelpKit

/// A turn's steps as the Steps view lists them: reads in a row by one agent as one line, each agent on a lane of its
/// own (the session's agent on the first), a subagent's lane branching off where it was started and joining back where
/// it reported, as the commit graph draws branches.
struct StepRow: Equatable {
    var step: AgentWork.Step
    var count = 1
    /// The lane of each agent shown on this row's line, before and after it.
    var before: Set<Int> = [], after: Set<Int> = []
    var lane = 0
    /// For a spawn or a report: the lane joined from or to.
    var link: Int?
    /// For a folded subagent's spawn: how many steps it took.
    var inside = 0

    /// The most lanes beside the steps: the session's agent and four others.
    static let maxLanes = 5

    /// Folds and lays out a turn's steps. With `filter`, only those agents'. The steps of the agents in `folded` are
    /// counted on the row that started them instead of listed, so a turn with dozens of subagents reads as the main
    /// agent's steps with one row per subagent.
    static func make(_ steps: [AgentWork.Step], filter: Set<Int>?, folded: Set<Int> = []) -> [StepRow] {
        var rows: [StepRow] = [], spawnRow: [Int: Int] = [:]
        for step in steps where filter.map({ $0.contains(step.agent) || step.other.map($0.contains) == true }) ?? true {
            if folded.contains(step.agent) {
                if step.kind != .report, let at = spawnRow[step.agent] { rows[at].inside += 1 }
                continue
            }
            if step.kind == .spawn, let other = step.other { spawnRow[other] = rows.count }
            if var last = rows.last, last.step.agent == step.agent, last.step.kind == step.kind,
                [.read, .search].contains(step.kind)
            {
                last.count += 1
                let name = (step.detail as NSString).lastPathComponent
                if !last.step.detail.components(separatedBy: ", ").map({ ($0 as NSString).lastPathComponent })
                    .contains(name)
                {
                    last.step.detail += ", " + (step.detail as NSString).lastPathComponent
                }
                rows[rows.count - 1] = last
                continue
            }
            rows.append(StepRow(step: step))
        }
        // An agent's lane opens at its first row and closes at its last (a report, or its last step if it never
        // reported back). At most `maxLanes`: past that, agents share the last one, so dozens of subagents stay
        // readable.
        var last: [Int: Int] = [:]
        for (index, row) in rows.enumerated() {
            last[row.step.agent] = index
            if let other = row.step.other, row.step.kind == .spawn { last[other] = max(last[other] ?? index, index) }
        }
        var lanes: [Int: Int] = [0: 0], users: [Int: Set<Int>] = [0: [0]]
        var open: Set<Int> { Set(users.filter { !$0.value.isEmpty }.keys) }
        func lane(_ agent: Int) -> Int {
            if let known = lanes[agent] { return known }
            let free = (1..<maxLanes).first { users[$0, default: []].isEmpty } ?? maxLanes - 1
            lanes[agent] = free
            users[free, default: []].insert(agent)
            return free
        }
        for index in rows.indices {
            rows[index].before = open
            let step = rows[index].step
            switch step.kind {
            case .spawn where step.other.map(folded.contains) == true:
                rows[index].lane = lane(step.agent)   // a folded subagent stays on the row: no lane of its own
            case .spawn:
                rows[index].link = lane(step.agent)
                rows[index].lane = step.other.map(lane) ?? 0
            case .report:
                rows[index].lane = lane(step.agent)
                rows[index].link = step.other.map(lane) ?? 0
            default:
                rows[index].lane = lane(step.agent)
            }
            for (agent, end) in last where end == index && agent != 0 {
                if let at = lanes[agent] { users[at]?.remove(agent) }
            }
            rows[index].after = open
        }
        return rows
    }
}

/// The Steps view's list: a rail drawn beside each row, the step's words, and its lines or time on the right. A click
/// opens what the step touched: a file, a subagent's journal, the agent's terminal.
@MainActor
final class StepsList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = KeyTable()
    private(set) lazy var scroll = table.plainList("steps")
    var onOpen: (AgentWork.Step) -> Void = { _ in }
    private var rows: [StepRow] = []
    private var names: [String] = [], agents: [AgentWork.Agent] = []
    private var start = Date()
    private weak var app: AppModel?

    override init() {
        super.init()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = TextSize.of(Metrics.row)
        table.intercellSpacing = .zero
        table.target = self
        table.action = #selector(clicked)
        table.onReturn = { [weak self] in self?.clicked() }
    }

    func show(_ work: AgentWork, names: [String], app: AppModel, filter: Set<Int>?) {
        let subagents = Set(work.agents.indices.filter { work.agents[$0].role == .subagent })
        let made = StepRow.make(work.steps, filter: filter, folded: filter == nil ? subagents : [])
        self.app = app
        agents = work.agents
        start =
            work.turn.flatMap { work.turns.indices.contains($0) ? work.turns[$0].at : nil } ?? work.steps.first?.at
            ?? Date()
        guard made != rows || names != self.names else { return }
        rows = made
        self.names = names
        table.reloadData()
        if let last = rows.indices.last { table.scrollRowToVisible(last) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { tableView.listRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row], step = item.step
        let rail = Rail(item, lanes: max(rows.map { ($0.before.union($0.after)).max() ?? 0 }.max() ?? 0, 0) + 1)
        var parts: [NSView] = [rail]
        if step.kind == .spawn, let other = step.other, agents.indices.contains(other) {
            parts.append(
                NSImageView(image: WorkModel.icon(agents[other], app: app, size: Metrics.iconSmall) ?? NSImage()))
        }
        let title = NSTextField.label(
            Self.title(item, names: names), font: .ui(TextSize.row, weight: step.kind == .spawn ? .medium : .regular))
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let words = item.inside > 0 ? String(localized: "\(item.inside) steps") + " · " + step.detail : step.detail
        let detail = NSTextField.label(
            words, font: .ui(TextSize.caption), color: .secondaryLabelColor, truncation: .byTruncatingTail)
        parts += [title, detail, NSView()]
        if step.kind == .edit, step.added + step.removed > 0 {
            var place = AgentWork.Place(kind: .file, name: "")
            place.added = step.added
            place.removed = step.removed
            parts.append(WorkFileList.lines(place))
        } else if [.spawn, .report, .failed, .ask].contains(step.kind) {
            let at = Duration.seconds(max(0, step.at.timeIntervalSince(start))).formatted(.time(pattern: .minuteSecond))
            parts.append(NSTextField.label(at, font: .uiDigits(TextSize.caption), color: .secondaryLabelColor))
        }
        let cell = NSStackView(views: parts)
        cell.spacing = Metrics.gap
        cell.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gapTight, bottom: 0, right: Metrics.inset)
        cell.toolTip = step.detail
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel([Self.title(item, names: names), step.detail].joined(separator: ", "))
        return cell
    }

    nonisolated static func title(_ row: StepRow, names: [String]) -> String {
        let step = row.step
        switch step.kind {
        case .read: return row.count > 1 ? String(localized: "Read ×\(row.count)") : String(localized: "Read a file")
        case .search: return row.count > 1 ? String(localized: "Search ×\(row.count)") : String(localized: "Search")
        case .edit: return String(localized: "Edit")
        case .command: return String(localized: "Ran")
        case .failed: return String(localized: "Failed")
        case .web: return String(localized: "Web")
        case .tool: return String(localized: "Tool")
        case .ask: return String(localized: "Asked you")
        case .spawn:
            return step.other.flatMap { names.indices.contains($0) ? names[$0] : nil } ?? String(localized: "Subagent")
        case .report: return String(localized: "Reported back")
        case .other: return step.tool
        }
    }

    @objc private func clicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(row) else { return }
        onOpen(rows[row].step)
    }

    /// The lanes beside one row: lines through it, the step's dot on its lane, a branch's curve where an agent starts
    /// or reports back.
    final class Rail: NSView {
        let row: StepRow, lanes: Int
        init(_ row: StepRow, lanes: Int) {
            self.row = row
            self.lanes = lanes
            super.init(frame: .zero)
            widthAnchor.constraint(equalToConstant: Self.x(lanes) - Metrics.gapTight).isActive = true
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        /// A lane's middle, from the left.
        static func x(_ lane: Int) -> CGFloat {
            Metrics.gap + CGFloat(lane) * (Metrics.inset + Metrics.gap) + Metrics.gapTight
        }
        static func color(_ lane: Int) -> NSColor {
            [NSColor.tertiaryLabelColor, .systemPurple, .systemTeal, .systemIndigo, .systemBrown][lane % 5]
        }

        override func draw(_ dirtyRect: NSRect) {
            let mid = bounds.midY, h = bounds.height
            for lane in row.before.union(row.after) {
                let x = Self.x(lane), path = NSBezierPath()
                let top = row.before.contains(lane) ? 0 : mid, bottom = row.after.contains(lane) ? h : mid
                guard top < bottom else { continue }
                path.move(to: NSPoint(x: x, y: top))
                path.line(to: NSPoint(x: x, y: bottom))
                stroke(path, lane)
            }
            if let link = row.link {
                let (from, to) = (Self.x(link), Self.x(row.lane)), path = NSBezierPath()
                if row.step.kind == .spawn {
                    path.move(to: NSPoint(x: from, y: 0))
                    path.curve(
                        to: NSPoint(x: to, y: mid), controlPoint1: NSPoint(x: from, y: mid),
                        controlPoint2: NSPoint(x: to, y: 0))
                } else {
                    path.move(to: NSPoint(x: to, y: mid))
                    path.curve(
                        to: NSPoint(x: from, y: h), controlPoint1: NSPoint(x: to, y: h),
                        controlPoint2: NSPoint(x: from, y: mid))
                }
                stroke(path, row.lane)
            }
            dot(NSPoint(x: Self.x(row.lane), y: mid))
        }

        private func stroke(_ path: NSBezierPath, _ lane: Int) {
            path.lineWidth = Metrics.lineGap
            Self.color(lane).setStroke()
            path.stroke()
        }

        private func dot(_ at: NSPoint) {
            let r = Metrics.gapTight, box = NSRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)
            let color = Self.color(row.lane)
            switch row.step.kind {
            case .edit:
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: box, xRadius: Metrics.lineGap, yRadius: Metrics.lineGap).fill()
            case .failed:
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: box).fill()
            case .spawn, .report:
                color.setFill()
                NSBezierPath(ovalIn: box.insetBy(dx: -1, dy: -1)).fill()
            case .command:
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5)).fill()
            default:
                let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
                NSColor.windowBackgroundColor.setFill()
                ring.fill()
                ring.lineWidth = 1.4
                if row.step.kind == .ask { ring.setLineDash([2, 1.5], count: 2, phase: 0) }
                (row.lane == 0 ? NSColor.secondaryLabelColor : color).setStroke()
                ring.stroke()
            }
        }
    }
}
