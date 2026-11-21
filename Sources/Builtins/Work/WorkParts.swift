import AppKit
import Core
import DesignKit
import KelpKit

/// The line under the panel's bar: what was asked, and how much was touched.
enum WorkSummary {
    static func line(_ work: AgentWork, turn: Int?) -> String {
        let files = work.places.filter { $0.kind == .file }
        let edited = files.filter { $0.edits > 0 || $0.byCommand }.count
        let outside = work.places.filter { ![.file, .folder].contains($0.kind) }.count
        var parts: [String] = []
        if let turn, work.turns.indices.contains(turn) { parts.append("«\(work.turns[turn].prompt)»") }
        parts.append(String(localized: "\(files.count) files"))
        if edited > 0 { parts.append(String(localized: "\(edited) edited")) }
        if outside > 0 { parts.append(String(localized: "\(outside) outside")) }
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
    enum Kind { case edit, read, outside, folder }
    var kind = Kind.read { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: Metrics.iconSmall, height: Metrics.iconSmall) }

    override func draw(_ dirtyRect: NSRect) {
        let side = Metrics.iconSmall - 3,
            box = NSRect(
                x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        switch kind {
        case .edit:
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: box, xRadius: Metrics.radiusXS / 2, yRadius: Metrics.radiusXS / 2).fill()
        case .read, .outside, .folder:
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.4
            if kind == .outside { ring.setLineDash([2, 1.5], count: 2, phase: 0) }
            if kind == .folder {
                NSColor.secondaryLabelColor.setFill()
                ring.fill()
            }
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
    private var places: [AgentWork.Place] = []
    private var chips: [Chip] = []
    private var own: [AgentWork.Place] = []
    private let more: NSTextField = .label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(more)
        heightAnchor.constraint(equalToConstant: Metrics.iconButton).isActive = true
        // It asks for no width: what doesn't fit goes into "+ N more".
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.iconButton) }

    func show(_ outside: [AgentWork.Place]) {
        guard outside != places else { return }
        places = outside
        chips.forEach { $0.removeFromSuperview() }
        isHidden = outside.isEmpty
        own = outside.filter { $0.kind == .own }
        chips = outside.filter { $0.kind != .own }.map { place in Chip(place) { [weak self] in self?.onOpen(place) } }
        chips.forEach { addSubview($0) }
        needsLayout = true
    }

    /// The count of places "+ N more" stands for, as laid out last.
    private(set) var hiddenCount = 0

    override func layout() {
        super.layout()
        let gap = Metrics.gapTight, height = bounds.height
        func moreWords(_ count: Int) -> String { count == 0 ? "" : String(localized: "+ \(count) more") }
        // Each chip goes in if it and, should any be left after it, the "+ N more" after it still fit.
        var x: CGFloat = 0, shown = 0
        for (index, chip) in chips.enumerated() {
            let width = chip.fittingSize.width
            let left = chips.count - index - 1 + own.count
            more.stringValue = moreWords(left)
            let reserve = left == 0 ? 0 : gap + more.fittingSize.width
            guard x + width + reserve <= bounds.width else { break }
            chip.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width + gap
            shown += 1
        }
        for (index, chip) in chips.enumerated() { chip.isHidden = index >= shown }
        hiddenCount = chips.count - shown + own.count
        let rest = chips.dropFirst(shown).map(\.place) + own
        more.stringValue = moreWords(hiddenCount)
        more.toolTip = rest.map(\.name).joined(separator: ", ")
        more.isHidden = hiddenCount == 0
        let size = more.fittingSize
        more.frame = NSRect(
            x: x, y: (height - size.height) / 2, width: min(size.width, max(0, bounds.width - x)), height: size.height)
    }

    private final class Chip: NSControl {
        let place: AgentWork.Place, label: NSTextField, icon = NSImageView()
        let tap: () -> Void
        init(_ place: AgentWork.Place, tap: @escaping () -> Void) {
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
            setAccessibilityRole(.button)
            setAccessibilityLabel(toolTip)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            Hatching.fill(NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusSM, yRadius: Metrics.radiusSM))
        }
        override func mouseDown(with event: NSEvent) { tap() }
        override func accessibilityPerformPress() -> Bool {
            tap()
            return true
        }
    }
}
