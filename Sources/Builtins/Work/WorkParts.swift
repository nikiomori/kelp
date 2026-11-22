import AppKit
import Core
import DesignKit
import KelpKit

/// The line under the panel's bar: what was asked, and how much was touched.
enum WorkSummary {
    static func line(_ work: AgentWork, turn: Int?) -> String {
        // By path: one file read in a dozen subagents' worktrees is one file, as the map draws it.
        let places = work.places.filter { $0.kind == .file }
        let files = Set(places.map(\.name))
        let edited = Set(places.filter { $0.edits > 0 || $0.byCommand }.map(\.name)).count
        let outside = work.places.filter { ![.file, .folder].contains($0.kind) }.count
        // The counts first, so a narrow panel cuts the prompt, which the turn menu also shows.
        var parts = files.isEmpty ? [] : [String(localized: "\(files.count) files")]
        if edited > 0 { parts.append(String(localized: "\(edited) edited")) }
        if outside > 0 { parts.append(String(localized: "\(outside) outside")) }
        if let turn, work.turns.indices.contains(turn) { parts.append("«\(work.turns[turn].prompt)»") }
        return parts.joined(separator: " · ")
    }

    /// What the agent does now, while it works: its last step ("Now: Read Models.swift"), or nil.
    static func now(_ work: AgentWork, working: Bool, names: [String]) -> String? {
        guard working, let last = work.steps.last else { return nil }
        let title = StepsList.title(StepRow(step: last), names: names)
        return String(localized: "Now: \(title) \((last.detail as NSString).lastPathComponent)")
    }

    /// The symbol that stands for a kind of place outside the project.
    static func symbol(_ kind: AgentWork.Kind) -> String {
        switch kind {
        case .web: "globe"
        case .machine: "server.rack"
        case .tool: "powerplug"
        case .packages: "shippingbox"
        case .own: "folder.badge.gearshape"
        case .outside, .folder: "folder"
        case .file: "doc"
        }
    }
}

/// A place's mark beside its name: a blue square for an edit, a ring for a read, a dashed ring outside the project.
@MainActor
final class PlaceMark: NSView {
    enum Kind { case edit, read }
    var kind = Kind.read { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: Metrics.iconSmall, height: Metrics.iconSmall) }

    override func draw(_ dirtyRect: NSRect) {
        let side = Metrics.iconSmall - 2 * Metrics.lineGap,
            box = NSRect(
                x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        switch kind {
        case .edit:
            NSColor.agentEditMark.setFill()
            NSBezierPath(roundedRect: box, xRadius: Metrics.radiusXS / 2, yRadius: Metrics.radiusXS / 2).fill()
        case .read:
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: Metrics.lineGap / 2, dy: Metrics.lineGap / 2))
            ring.lineWidth = Metrics.stroke
            NSColor.secondaryLabelColor.setStroke()
            ring.stroke()
        }
    }
}

/// The places outside the project as a row of hatched chips, as many as fit whole, in order; then "+ 5 more" for
/// the rest (the agent's own folders always among them), their names in its tooltip. A chip opens what Kelp can open
/// (a site in its browser).
@MainActor
final class OutsideChips: NSView {
    var onOpen: (AgentWork.Place) -> Void = { _ in }
    /// Whether a place has somewhere to go on a click (a site, a tool, a folder on this Mac).
    var opens: (AgentWork.Place) -> Bool = { _ in true }
    private var places: [AgentWork.Place] = []
    private var chips: [Chip] = []
    private var own: [AgentWork.Place] = []
    private lazy var more = TextButton("", target: self, action: #selector(showRest))
    /// The most rows of chips; past them, "+ N more" opens a menu of the rest.
    static let rows = 3
    private var usedRows = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        more.font = .ui(TextSize.caption)
        addSubview(more)
        // It asks for no width: it wraps into the width it is given.
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: CGFloat(usedRows) * Metrics.iconButton + CGFloat(usedRows - 1) * Metrics.gapTight)
    }
    override var isFlipped: Bool { true }

    func show(_ outside: [AgentWork.Place]) {
        guard outside != places else { return }
        places = outside
        chips.forEach { $0.removeFromSuperview() }
        isHidden = outside.isEmpty
        own = outside.filter { $0.kind == .own }
        chips = outside.filter { $0.kind != .own }.map { place in
            Chip(place, tap: opens(place) ? { [weak self] in self?.onOpen(place) } : nil)
        }
        chips.forEach { addSubview($0) }
        needsLayout = true
    }

    /// The count of places "+ N more" stands for, as laid out last.
    private(set) var hiddenCount = 0
    private var rest: [AgentWork.Place] = []

    override func layout() {
        super.layout()
        let gap = Metrics.gapTight, height = Metrics.iconButton
        // Only the agent's own folders left over: their names say more than a count ("+ /tmp, ~/.claude").
        func moreWords(_ count: Int) -> String {
            if count == 0 { return "" }
            return count == own.count
                ? "+ " + own.map(\.name).joined(separator: ", ") : String(localized: "+ \(count) more")
        }
        // Chips fill rows left to right; on the last row each goes in if, should any be left after it, the "+ N more"
        // after it still fits. A chip wider than a row is cut in the middle.
        var x: CGFloat = 0, row = 0, shown = 0
        for (index, chip) in chips.enumerated() {
            let width = min(chip.fittingSize.width, bounds.width)
            let left = chips.count - index - 1 + own.count
            more.title = moreWords(left)
            let last = row == Self.rows - 1
            let reserve = left == 0 || !last ? 0 : gap + more.fittingSize.width
            if x > 0, x + width + reserve > bounds.width {
                guard !last else { break }
                (x, row) = (0, row + 1)
                if row == Self.rows - 1, width + (left == 0 ? 0 : gap + more.fittingSize.width) > bounds.width,
                    index > 0
                {
                    break
                }
            }
            let fit = max(0, min(width, bounds.width - x - (row == Self.rows - 1 ? reserve : 0)))
            chip.frame = NSRect(x: x, y: CGFloat(row) * (height + gap), width: fit, height: height)
            x += fit + gap
            shown += 1
        }
        for (index, chip) in chips.enumerated() { chip.isHidden = index >= shown }
        hiddenCount = chips.count - shown + own.count
        rest = chips.dropFirst(shown).map(\.place) + own
        more.title = moreWords(hiddenCount)
        more.isHidden = hiddenCount == 0
        if !more.isHidden, x > 0, x + more.fittingSize.width > bounds.width, row < Self.rows - 1 {
            (x, row) = (0, row + 1)
        }
        let size = more.fittingSize
        more.frame = NSRect(
            x: x, y: CGFloat(row) * (height + gap) + (height - size.height) / 2,
            width: min(size.width, max(0, bounds.width - x)), height: size.height)
        if row + 1 != usedRows {
            usedRows = row + 1
            invalidateIntrinsicContentSize()
        }
    }

    /// The places that didn't fit, as a menu: each does what its chip would.
    @objc private func showRest() {
        let menu = NSMenu()
        for (index, place) in rest.enumerated() {
            let item = NSMenuItem(title: place.name, action: #selector(openRest(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = .symbol(WorkSummary.symbol(place.kind))
            item.isEnabled = opens(place)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: more.frame.minX, y: more.frame.maxY), in: self)
    }

    @objc private func openRest(_ item: NSMenuItem) {
        if rest.indices.contains(item.tag) { onOpen(rest[item.tag]) }
    }

    private final class Chip: NSControl {
        let place: AgentWork.Place, label: NSTextField, icon = NSImageView()
        let tap: (() -> Void)?
        /// Without `tap`, a place there's nowhere to go from (a host, a web search): it shows, but isn't a button.
        init(_ place: AgentWork.Place, tap: (() -> Void)?) {
            self.place = place
            self.tap = tap
            label = .label(place.name, font: .ui(TextSize.caption), truncation: .byTruncatingMiddle)
            super.init(frame: .zero)
            // A chip shows its whole name or gives way as a whole: the row drops the last chips that don't fit.
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            setContentHuggingPriority(.defaultHigh, for: .horizontal)
            icon.image = .symbol(WorkSummary.symbol(place.kind))
            icon.symbolConfiguration = .init(pointSize: Metrics.iconSmall, weight: Metrics.iconWeight)
            icon.contentTintColor = .secondaryLabelColor
            let row = NSStackView(views: [icon, label])
            row.spacing = Metrics.gapTight
            row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gap, bottom: 0, right: Metrics.gap)
            pin(row)
            toolTip = [place.name, place.detail].compactMap { $0 }.joined(separator: " · ")
            setAccessibilityRole(tap == nil ? .staticText : .button)
            setAccessibilityLabel(toolTip)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            Hatching.fill(NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusSM, yRadius: Metrics.radiusSM))
        }
        override func mouseDown(with event: NSEvent) { tap?() }
        override func accessibilityPerformPress() -> Bool {
            tap?()
            return tap != nil
        }
    }
}

/// The turn menu the panel and the Map tab share: the last turn first, then each earlier one by its prompt and time,
/// then the whole session. Built again only when the turns change, so a menu held open while the agent works stays.
@MainActor
enum TurnMenu {
    static func fill(_ pop: NSPopUpButton, work: AgentWork?, model: WorkModel) {
        let turns = work?.turns ?? []
        pop.isHidden = turns.isEmpty
        let items = turns.enumerated().reversed().map { index, turn in
            (
                index == turns.count - 1
                    ? String(localized: "Last Turn")
                    : "“\(turn.prompt.prefix(40))” · \(turn.at.formatted(date: .omitted, time: .shortened))", index,
                turn.prompt
            )
        }
        let titles = items.map(\.0) + [String(localized: "Whole Session")]
        if pop.itemArray.filter({ !$0.isSeparatorItem }).map(\.title) != titles {
            pop.removeAllItems()
            // Items added to the menu itself: `addItem(withTitle:)` drops one whose title is already there (two turns
            // asked the same thing in one minute).
            for (title, tag, tip) in items + [(String(localized: "Whole Session"), -1, nil)] {
                if tag < 0 { pop.menu?.addItem(.separator()) }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = tag
                item.toolTip = tip
                pop.menu?.addItem(item)
            }
        }
        pop.selectItem(withTag: model.whole ? -1 : (model.turn ?? turns.count - 1))
    }

    static func pick(_ pop: NSPopUpButton, model: WorkModel) {
        let tag = pop.selectedTag()
        model.whole = tag < 0
        model.turn = tag < 0 || tag == (model.work?.turns.count ?? 0) - 1 ? nil : tag
    }
}

/// What just came into a drawing, lit for as long as Needs You flashes. A newer flash starts the time again.
@MainActor
final class Flash {
    private(set) var lit: Set<String> = []
    private var timer: Timer?

    /// Lights `ids` (none with Reduce Motion), and calls `changed` now and when they go out.
    func start(_ ids: Set<String>, changed: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        lit = Motion.reduced ? [] : ids
        changed()
        guard !lit.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Motion.flash, repeats: false) { [weak self] _ in
            // A timer scheduled on the main run loop fires on the main thread.
            MainActor.assumeIsolated {
                self?.lit = []
                changed()
            }
        }
    }
}
