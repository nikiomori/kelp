import AppKit
import Core
import DesignKit
import KelpKit

/// A side of a screen the strip hides behind, as a picture-in-picture video does in Dia. Not the foot (the Dock) nor the head
/// (the menu bar).
enum StripEdge: String { case left, right }

/// The strip behind an edge, without a window.
@MainActor
extension StripModel {
    /// What stays out: its handle, with the one sign on it.
    static let sliver: CGFloat = 18
    /// The handle's room in the strip, on the side away from the edge.
    static let handle: CGFloat = 20
    /// How long a question's line stays out beside the sliver; a failure's is shorter, as it waits for nothing.
    static let questionStays: TimeInterval = 6, failureStays: TimeInterval = 4

    /// Let go more than a third past a side: it hides there.
    static func edge(dropped frame: NSRect, in area: NSRect) -> StripEdge? {
        if frame.maxX - area.maxX > frame.width / 3 { return .right }
        if area.minX - frame.minX > frame.width / 3 { return .left }
        return nil
    }

    /// A side with another screen past it isn't an edge: what hides would show there.
    static func outer(_ edge: StripEdge, of screen: NSRect, among others: [NSRect]) -> Bool {
        !others.contains { other in
            let beside =
                edge == .right
                ? other.minX >= screen.maxX - 1 && other.minX <= screen.maxX + 1
                : other.maxX <= screen.minX + 1 && other.maxX >= screen.minX - 1
            return beside && other.maxY > screen.minY && other.minY < screen.maxY
        }
    }

    /// Behind `edge` with its sliver out, or all of it out (`out`: the pointer on it); `y` up from the area's foot.
    static func tucked(_ size: NSSize, in area: NSRect, edge: StripEdge, y: CGFloat, out: Bool) -> NSRect {
        let originX =
            switch edge {
            case .right: out ? area.maxX - size.width - margin : area.maxX - sliver
            case .left: out ? area.minX + margin : area.minX + sliver - size.width
            }
        let top = max(area.minY + margin, min(area.minY + y, area.maxY - size.height - margin))
        return NSRect(x: originX, y: top, width: size.width, height: size.height)
    }

    /// Between a strip that's out and the edge it came from: a pointer pushed against the edge, still on it in all but name.
    static func inGap(_ p: NSPoint, beside strip: NSRect, edge: StripEdge) -> Bool {
        let withinX =
            switch edge {
            case .right: p.x >= strip.maxX && p.x <= strip.maxX + margin + 1
            case .left: p.x <= strip.minX && p.x >= strip.minX - margin - 1
            }
        return withinX && p.y >= strip.minY && p.y <= strip.maxY
    }

    /// What comes out of the edge as a line: a question or a failure not told yet, the oldest question first. Finished work
    /// is only the sliver's dot, and work going on says nothing.
    static func news(_ items: [StripItem], told: Set<String>) -> StripItem? {
        items.filter { $0.cell <= .failed && !told.contains(newsKey($0)) }.min {
            ($0.cell, $0.since) < ($1.cell, $1.since)
        }
    }

    static func newsKey(_ item: StripItem) -> String { "\(item.session)|\(item.since.timeIntervalSince1970)" }
}

/// The sliver's one sign: a short bar in the state's colour that glows for a question or a failure, a dot when something
/// finished, a grey bar breathing while they work.
final class StripGlint: NSView {
    static let size = NSSize(width: 6, height: 14)
    private let mark = CALayer()

    var cell: DockFace.Cell? { didSet { if cell != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(mark)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let size = Self.size, dot = cell == .done
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame =
            dot
            ? CGRect(x: 0, y: (size.height - size.width) / 2, width: size.width, height: size.width)
            : CGRect(x: 1, y: 0, width: size.width - 2, height: size.height)
        mark.cornerRadius = dot ? size.width / 2 : (size.width - 2) / 2
        let color: NSColor =
            switch cell {
            case .asks: .systemOrange
            case .failed: .systemRed
            case .done: .labelColor
            default: .secondaryLabelColor
            }
        mark.backgroundColor = color.cgColor
        let glows = cell == .asks || cell == .failed
        mark.shadowColor = color.cgColor
        mark.shadowRadius = glows ? 4 : 0
        mark.shadowOpacity = glows ? 0.9 : 0
        mark.shadowOffset = .zero
        CATransaction.commit()
        mark.removeAllAnimations()
        guard cell == .working, !Motion.reduced else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.35
        breathe.duration = Motion.wait / 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)   // as the spinners
        mark.add(breathe, forKey: "breathe")
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }   // animations stop when a view leaves a window
}

/// Beside a hidden strip, one line out of the edge: the project and what it wants. A click brings the strip out.
@MainActor
final class StripLine {
    private static let height: CGFloat = 30, icon: CGFloat = 20
    private let button = LineButton()
    private lazy var panel: StripPanel = StripPanel.floating(button, radius: Self.height / 2, fullScreen: true)
    private var ends: Timer?

    var onClick: (() -> Void)? {
        get { button.onClick }
        set { button.onClick = newValue }
    }

    /// Out of `edge` beside the sliver of a strip at `strip`, for `stays` seconds.
    func show(_ item: StripItem, app: AppModel, by strip: NSRect, edge: StripEdge, stays: TimeInterval) {
        button.show(item, app: app)
        let content = panel.contentView
        content?.layoutSubtreeIfNeeded()
        let size = NSSize(width: content?.fittingSize.width ?? 0, height: Self.height)
        // Beside the sliver, which is the strip's inner end: the rest of it is past the edge.
        let originX = edge == .right ? strip.minX - Metrics.gapWide - size.width : strip.maxX + Metrics.gapWide
        let frame = NSRect(x: originX, y: strip.midY - size.height / 2, width: size.width, height: size.height)
        let from = Motion.reduced ? 0 : (edge == .right ? 1 : -1) * StripModel.handle
        panel.setFrame(frame.offsetBy(dx: from, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.appear)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        ends?.invalidate()
        ends = Timer.scheduledTimer(withTimeInterval: stays, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }   // the main run loop's timer
        }
    }

    var isShowing: Bool { panel.isVisible }
    func apply(fullScreen: Bool) { panel.apply(fullScreen: fullScreen) }

    func hide() {
        ends?.invalidate()
        guard panel.isVisible else { return }
        let shown = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.fast)
            shown.animator().alphaValue = 0
        } completionHandler: {
            // AppKit runs it on the main thread
            MainActor.assumeIsolated { if shown.alphaValue == 0 { shown.orderOut(nil) } }
        }
    }

    /// The whole line is the button, and takes the click that reaches it with Kelp behind.
    private final class LineButton: PointerControl {
        var onClick: (() -> Void)?
        private let icon = NSImageView(), words = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer?.cornerRadius = StripLine.height / 2
            icon.wantsLayer = true
            icon.layer?.cornerRadius = Metrics.radiusXS
            icon.layer?.masksToBounds = true
            icon.imageScaling = .scaleProportionallyUpOrDown
            words.lineBreakMode = .byTruncatingTail
            words.maximumNumberOfLines = 1
            let row = NSStackView(views: [icon, words])
            row.spacing = Metrics.gapWide
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: StripLine.height),
                icon.widthAnchor.constraint(equalToConstant: StripLine.icon),
                icon.heightAnchor.constraint(equalToConstant: StripLine.icon),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: (StripLine.height - StripLine.icon) / 2),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
                row.centerYAnchor.constraint(equalTo: centerYAnchor),
                words.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        func show(_ item: StripItem, app: AppModel) {
            if let repo = item.repo { ProjectIcon.show(repo, in: icon, app: app) }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                icon.layer?.backgroundColor = NSColor.fillHover.cgColor
            }
            let line = NSMutableAttributedString(
                string: item.name,
                attributes: [.font: NSFont.ui(12, weight: .medium), .foregroundColor: NSColor.labelColor])
            let color: NSColor = item.cell == .asks ? .textOrange : .textRed
            line.append(
                NSAttributedString(
                    string: "  " + StripModel.brief(item.words ?? ""),
                    attributes: [.font: NSFont.ui(12), .foregroundColor: color]))
            words.attributedStringValue = line
            let says = [item.name, item.words].compactMap { $0 }.joined(separator: ", ")
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(says)
        }

        override func clicked() { onClick?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    }
}
