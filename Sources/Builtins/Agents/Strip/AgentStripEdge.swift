import AppKit
import Core
import DesignKit
import KelpKit

/// A side of a screen that the strip can hide behind, as a picture-in-picture video does in Dia. The strip never hides
/// behind the bottom (the Dock) or the top (the menu bar).
enum StripEdge: String, Codable { case left, right }

/// The geometry of a strip behind an edge, worked out without a window.
@MainActor
extension StripModel {
    /// How much of a hidden strip stays out: its handle, with the glint on it.
    static let sliver: CGFloat = 18
    /// The room the handle takes in the strip, on the side away from the edge.
    static let handle: CGFloat = 20
    /// How long a question's line stays out beside the sliver; a failure's line stays out for less time, since it waits
    /// for nothing.
    static let questionStays: TimeInterval = 6, failureStays: TimeInterval = 4, doneStays: TimeInterval = 3

    /// Returns the side to hide behind when the strip is let go more than a third past it.
    static func edge(dropped frame: NSRect, in area: NSRect) -> StripEdge? {
        if frame.maxX - area.maxX > frame.width / 3 { return .right }
        if area.minX - frame.minX > frame.width / 3 { return .left }
        return nil
    }

    /// Whether a side of the screen is an outer edge. A side with another screen past it isn't, because a strip hidden
    /// there would show on that screen.
    static func outer(_ edge: StripEdge, of screen: NSRect, among others: [NSRect]) -> Bool {
        !others.contains { other in
            let beside =
                edge == .right
                ? other.minX >= screen.maxX - 1 && other.minX <= screen.maxX + 1
                : other.maxX <= screen.minX + 1 && other.maxX >= screen.minX - 1
            return beside && other.maxY > screen.minY && other.minY < screen.maxY
        }
    }

    /// Returns the frame of a strip behind `edge` with only its sliver out, or all of it out when `out` is set (the
    /// pointer is on it). `y` is measured up from the bottom of the area.
    static func tucked(_ size: NSSize, in area: NSRect, edge: StripEdge, y: CGFloat, out: Bool) -> NSRect {
        let originX =
            switch edge {
            case .right: out ? area.maxX - size.width - margin : area.maxX - sliver
            case .left: out ? area.minX + margin : area.minX + sliver - size.width
            }
        let top = max(area.minY + margin, min(area.minY + y, area.maxY - size.height - margin))
        return NSRect(x: originX, y: top, width: size.width, height: size.height)
    }

    /// Whether the point is in the gap between a strip that's out and the edge it came from. A pointer pushed against
    /// the edge there is still on the strip in all but name.
    static func inGap(_ point: NSPoint, beside strip: NSRect, edge: StripEdge) -> Bool {
        let withinX =
            switch edge {
            case .right: point.x >= strip.maxX && point.x <= strip.maxX + margin + 1
            case .left: point.x <= strip.minX && point.x >= strip.minX - margin - 1
            }
        return withinX && point.y >= strip.minY && point.y <= strip.maxY
    }

    /// Returns the news that comes out of the edge as a line or flashes its tile. That is each item not told yet that
    /// is as loud as `upTo` (questions, failures or finished work, whatever brings the strip up, see `loudest`), with
    /// the oldest question first. Work going on is never news.
    static func news(_ items: [StripItem], told: Set<String>, upTo: DockFace.Cell = .failed) -> [StripItem] {
        items.filter { $0.cell != .working && $0.cell <= upTo && !told.contains(newsKey($0)) }.sorted {
            ($0.cell, $0.since) < ($1.cell, $1.since)
        }
    }

    /// Returns how long a line stays out. A question stays longest, a failure less, and finished work only a moment,
    /// because it waits for nothing.
    static func stays(_ cell: DockFace.Cell) -> TimeInterval {
        cell == .asks ? questionStays : cell == .failed ? failureStays : doneStays
    }

    static func newsKey(_ item: StripItem) -> String { "\(item.session)|\(item.since.timeIntervalSince1970)" }
}

/// The one mark on the sliver of a hidden strip. It is a short bar in the state's colour that glows for a question or a
/// failure (and breathes for a question), a dot when something finished, and a still grey bar while the agents work.
final class StripGlint: NSView {
    static let size = NSSize(width: 6, height: 14)
    private let mark = CALayer(), second = CALayer()

    var cell: DockFace.Cell? { didSet { if cell != oldValue { needsDisplay = true } } }
    /// Set when more than one workspace asks, so the glint shows two bars and a second question doesn't hide behind the
    /// first.
    var twice = false { didSet { if twice != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(mark)
        layer?.addSublayer(second)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
        followReduceMotion(#selector(motionChanged))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func motionChanged() { needsDisplay = true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let size = Self.size, dot = cell == .done, two = twice && cell == .asks
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bar: CGFloat = two ? 2 : size.width - 2
        mark.frame =
            dot
            ? CGRect(x: 0, y: (size.height - size.width) / 2, width: size.width, height: size.width)
            : CGRect(x: two ? 0 : 1, y: 0, width: bar, height: size.height)
        second.frame = CGRect(x: size.width - bar, y: 0, width: bar, height: size.height)
        second.isHidden = !two
        let color: NSColor =
            switch cell {
            case .asks: .systemOrange
            case .failed: .systemRed
            case .done: .labelColor
            default: .secondaryLabelColor
            }
        let glows = cell == .asks || cell == .failed
        for layer in [mark, second] {
            layer.cornerRadius = dot ? size.width / 2 : bar / 2
            layer.backgroundColor = color.cgColor
            layer.shadowColor = color.cgColor
            layer.shadowRadius = glows ? 4 : 0
            layer.shadowOpacity = glows ? 0.9 : 0
            layer.shadowOffset = .zero
            layer.removeAllAnimations()
        }
        CATransaction.commit()
        // Only a question breathes, because it waits for the user, as a tab's glow does. Work going on is the quiet
        // state and stands still.
        guard cell == .asks, !Motion.reduced else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.35
        breathe.duration = Motion.breathe
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.beginTime = Motion.beat(2 * Motion.breathe)
        breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)   // as the spinners
        for layer in [mark, second] { layer.add(breathe, forKey: "breathe") }
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

/// One line that comes out of the edge beside a hidden strip, with the project and what its agent wants. A click opens
/// the agent's card, or brings the strip out when the agent is still at work.
@MainActor
final class StripLine {
    private static let height: CGFloat = 30, icon: CGFloat = 20
    private let button = LineButton()
    private lazy var panel: StripPanel = StripPanel.floating(button, radius: Self.height / 2, fullScreen: true)
    private var ends: Timer?
    private var stays: TimeInterval = 0
    /// Called when the line went away by itself because its time was up, so the next news can come out.
    var onGone: (() -> Void)?

    var onClick: (() -> Void)? {
        get { button.onClick }
        set { button.onClick = newValue }
    }

    var frame: NSRect { panel.frame }

    /// Shows the line out of `edge`, beside the sliver of the strip whose frame is `strip`. It stays as long as its
    /// news lasts (`StripModel.stays`) or while the pointer is on it. `more` is how much news waits behind it.
    func show(_ item: StripItem, more: Int, app: AppModel, by strip: NSRect, edge: StripEdge) {
        button.show(item, more: more, app: app)
        button.onHover = { [weak self] on in self?.hold(on) }
        stays = StripModel.stays(item.cell)
        let content = panel.contentView
        content?.layoutSubtreeIfNeeded()
        let size = NSSize(width: content?.fittingSize.width ?? 0, height: Self.height)
        // Next to the sliver, which is the strip's inner end, because the rest of the strip is past the edge.
        let originX = edge == .right ? strip.minX - Metrics.gapWide - size.width : strip.maxX + Metrics.gapWide
        let frame = NSRect(x: originX, y: strip.midY - size.height / 2, width: size.width, height: size.height)
        let from = Motion.reduced ? 0 : (edge == .right ? 1 : -1) * StripModel.handle
        panel.slideIn(to: frame, by: CGVector(dx: from, dy: 0))
        hold(false)
    }

    /// Keeps the line out while the pointer is on it. Once the pointer leaves, the line goes after its time, or after a
    /// moment if its time is already up.
    private func hold(_ on: Bool) {
        ends?.invalidate()
        guard !on else { return }
        ends = Timer.scheduledTimer(withTimeInterval: max(stays, Motion.linger), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {   // the main run loop's timer
                self?.hide()
                self?.onGone?()
            }
        }
        stays = 0
    }

    var isShowing: Bool { panel.isVisible }
    func apply(fullScreen: Bool) { panel.apply(fullScreen: fullScreen) }

    func hide() {
        ends?.invalidate()
        guard panel.isVisible else { return }
        let shown = panel
        shown.fadeOut { shown.alphaValue != 0 }
    }

    /// The whole line is one button, and it takes a click even while Kelp is behind other apps.
    private final class LineButton: PointerControl {
        private let icon = NSImageView(), words = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            tracksAlways = true   // so a line under the pointer stays out while Kelp is behind other apps
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

        func show(_ item: StripItem, more: Int, app: AppModel) {
            if let repo = item.repo { ProjectIcon.show(repo, in: icon, app: app) }
            fillIcon()
            let line = NSMutableAttributedString(
                string: item.name,
                attributes: [.font: NSFont.ui(TextSize.row, weight: .medium), .foregroundColor: NSColor.labelColor])
            line.append(
                NSAttributedString(
                    string: "  " + StripModel.brief(item.words ?? ""),
                    attributes: [.font: NSFont.ui(TextSize.row), .foregroundColor: item.cell.wordsColor]))
            if more > 0 {
                line.append(
                    NSAttributedString(
                        string: "  +\(more)",
                        attributes: [
                            .font: NSFont.uiDigits(TextSize.caption), .foregroundColor: NSColor.secondaryLabelColor
                        ]))
            }
            words.attributedStringValue = line
            let says = [item.name, item.words].compactMap { $0 }.joined(separator: ", ")
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(says)
        }

        /// The fill behind the icon is a layer's colour, which keeps the appearance it was set in, so it is set again
        /// at the moment the Mac goes light or dark with the line out.
        private func fillIcon() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                icon.layer?.backgroundColor = NSColor.fillHover.cgColor
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            fillIcon()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    }
}
