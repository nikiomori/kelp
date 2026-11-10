import AppKit
import Core
import DesignKit

/// On an agent's row, the agents it started and its own subagents: a dot for each, so they take no rows of their own and
/// don't compete with the name. Up to four; past that one dot, the most urgent, and how many are at work. Over it the hover
/// card lists them; a click brings the card up at once.
@MainActor
final class ChildrenBadge: PointerControl {
    /// Filled works, hollow finished; the two that want someone are coloured. In the order they stand.
    enum Pip: Int, Comparable {
        case failed, asks, works, finished
        static func < (lhs: Pip, rhs: Pip) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    static let mostPips = 4
    private let pips = PipsView(), count = NSTextField(labelWithString: "")
    var opened: () -> Void = {}

    init() {
        super.init(frame: .zero)
        count.font = .uiDigits(TextSize.caption, weight: .medium)
        count.textColor = .secondaryLabelColor
        let row = NSStackView(views: [pips, count])
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        layer?.cornerRadius = Metrics.radiusXS
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What it shows for an agent: one a plan limit stopped hasn't finished, whatever its status says, and Kelp isn't
    /// continuing it by itself: someone has to decide.
    static func status(_ session: Session) -> AgentStatus {
        session.status == .done && session.limitHit != nil && session.continueAt == nil
            ? .waiting : SidebarCell.shownStatus(session)
    }

    /// The dots for what runs under an agent, and the number beside them when they don't fit. A turn's finished subagents
    /// stand only beside one still at work: a started agent lives on until its parent ends, so it always shows.
    static func marks(kids: [Session], running: [Subagent], finished: [Subagent]) -> (pips: [Pip], count: Int?) {
        guard !kids.isEmpty || !running.isEmpty else { return ([], nil) }
        let started: [Pip] = kids.map {
            switch status($0) {
            case .waiting: .asks
            case .error: .failed
            case .working: .works
            default: .finished
            }
        }
        let all =
            (started + running.map { $0.asks == true ? .asks : .works }
            + (running.isEmpty ? [] : finished.map { _ in .finished })).sorted()
        if all.count <= mostPips { return (all, nil) }
        let atWork = all.count { $0 != .finished }
        return (Array(all.prefix(1)), atWork > 0 ? atWork : all.count)
    }

    func show(_ kids: [Session], running: [Subagent], finished: [Subagent]) {
        let marks = Self.marks(kids: kids, running: running, finished: finished)
        isHidden = marks.pips.isEmpty
        pips.pips = marks.pips
        count.isHidden = marks.count == nil
        count.stringValue = marks.count.map(String.init) ?? ""
        let done = finished.count + kids.count { Self.status($0) == .done }
        setAccessibilityLabel(String(localized: "\(kids.count + running.count) at work, \(done) finished"))
    }

    override func clicked() { opened() }
}

/// The dots themselves: layers, so a fill goes as it comes (`Motion.appear`) instead of switching.
@MainActor
final class PipsView: NSView {
    private static let side: CGFloat = 5, gap: CGFloat = 2
    var pips: [ChildrenBadge.Pip] = [] {
        didSet {
            guard pips != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    private var dots: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Two to a line, so four dots make a square of 12 pt and leave the name its width: column and line of dot `index`
    /// among `count`, the first line on top.
    static func cell(_ index: Int, of count: Int) -> (column: Int, line: Int) {
        count <= 2 ? (index, 0) : (index % 2, index / 2)
    }
    static func grid(_ count: Int) -> (columns: Int, lines: Int) {
        count <= 2 ? (count, count > 0 ? 1 : 0) : (2, (count + 1) / 2)
    }

    override var intrinsicContentSize: NSSize {
        let grid = Self.grid(pips.count), step = Self.side + Self.gap
        return NSSize(
            width: max(0, CGFloat(grid.columns) * step - Self.gap),
            height: max(0, CGFloat(grid.lines) * step - Self.gap))
    }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {   // the appearance is current here
        addDots()
        CATransaction.begin()
        if Motion.reduced {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(Motion.appear)
        }
        for (index, dot) in dots.enumerated() {
            dot.isHidden = index >= pips.count
            if index < pips.count { paint(dot, pips[index]) }
        }
        CATransaction.commit()
    }

    /// Each dot in its cell; the layer's origin is at the bottom, so the first line is the top one.
    private func place() {
        let lines = Self.grid(pips.count).lines, step = Self.side + Self.gap
        for (index, dot) in dots.enumerated() where index < pips.count {
            let cell = Self.cell(index, of: pips.count)
            dot.frame = NSRect(
                x: CGFloat(cell.column) * step, y: CGFloat(lines - 1 - cell.line) * step, width: Self.side,
                height: Self.side)
        }
    }

    private func addDots() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while dots.count < pips.count {
            let dot = CALayer()
            dot.cornerRadius = Self.side / 2
            dot.shadowOffset = .zero
            dot.shadowRadius = 2
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        place()   // the count changes the grid: dots move without sliding
        CATransaction.commit()
    }

    private func paint(_ dot: CALayer, _ pip: ChildrenBadge.Pip) {
        let color: NSColor = pip == .asks ? .systemOrange : pip == .failed ? .systemRed : .secondaryLabelColor
        dot.backgroundColor = pip == .finished ? NSColor.clear.cgColor : color.cgColor
        dot.borderColor = color.cgColor
        dot.borderWidth = pip == .finished ? 1 : 0
        dot.shadowColor = color.cgColor
        dot.shadowOpacity = pip == .asks ? 0.8 : 0
    }
}

extension Subagent {
    /// What it does, or else all that's known of it.
    var title: String { task ?? (kind.isEmpty ? String(localized: "Subagent") : kind) }
    /// Its kind beside what it does: nine in ten are general-purpose, which tells them apart from nothing.
    var shownKind: String? { task == nil || kind.isEmpty || kind == "general-purpose" ? nil : kind }
}

extension SidebarCell {
    /// A row's second line: what it asks itself, or else what a child of its asks (`children`: the agents it started
    /// and theirs, `AppModel.children(of:)`), under the child's name.
    /// `back`: why a parked agent came back (`Arrangement.parkedBack`), said when nothing more urgent is. `plans`: what
    /// a plan limit that stopped one says (`Contributions.plans`).
    static func line(
        _ session: Session, mode: String, children: [Session], back: String? = nil, plans: PlanWords? = nil
    ) -> (prefix: (String, NSColor)?, text: String)? {
        let own = askLine(session, mode: mode, plans: plans)
        guard own?.prefix == nil else { return own }
        if let back { return ((String(localized: "Back:"), .secondaryLabelColor), back) }
        for child in children {
            if let line = askLine(child, mode: mode, plans: plans), let color = line.prefix?.1 {
                return ((child.displayTitle + ":", color), line.text)
            }
        }
        return own
    }
}

/// What an agent's row says of its state, for the sidebar and everyone who counts like it.
extension SidebarCell {
    /// "Limit: resets 3:40 PM": a plan limit stopped it. "Asks: may I run npm test?", "Failed: rate limit until 14:00": what an
    /// agent that needs you wants, in its own words (its summary); with `always` every agent says what it's on. Nil: no second
    /// line.
    static func askLine(_ session: Session, mode: String, plans: PlanWords? = nil) -> (
        prefix: (String, NSColor)?, text: String
    )? {
        let st = shownStatus(session), text = session.summary.isEmpty ? st.words : session.summary
        if mode != "never", let limit = plans?.rowLine(session) { return ((limit.word, .textOrange), limit.text) }
        switch (mode, st) {
        case ("never", _): return nil
        case (_, .waiting): return ((String(localized: "Asks:"), .textOrange), text)
        case (_, .error): return ((String(localized: "Failed:"), .textRed), text)
        case ("always", _): return (nil, text)
        default: return nil
        }
    }

    /// Asks for you, failed, or finished and not looked at yet.
    static func wantsYou(_ session: Session) -> Bool {
        let st = shownStatus(session)
        return session.isChat && (st == .waiting || st == .error || (st == .done && session.unread))
    }

    static func shownStatus(_ session: Session) -> AgentStatus { session.shownStatus }

    /// Something to look at: finished or asking, and not opened since (bold, like unread mail).
    static func isNews(_ session: Session) -> Bool {
        session.unread && [.done, .waiting, .error].contains(shownStatus(session))
    }
}
