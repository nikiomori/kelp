import AppKit
import Core
import DesignKit
import KelpKit

/// A panel that takes clicks and a typed reply and leaves the active app active. It stays up with Kelp behind, on every Space, and
/// at a level under the Dock's.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Moved by the pointer, and let go: how fast it was going then (points a second, up positive; still if the hand
    /// stopped first).
    var onDropped: ((CGVector) -> Void)?
    /// ⎋ while it has the keys (a card).
    var onCancel: (() -> Void)?
    /// What a hand trembles by: less than this is a click.
    private static let dragFrom: CGFloat = 4

    /// Follows the pointer until the button is let go; says if it went anywhere, as if not this was a click.
    func drag(from down: NSEvent) -> Bool {
        let start = frame.origin, from = Self.onScreen(down)
        var moved = false, recent: [(at: CGPoint, time: TimeInterval)] = []
        while let event = nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let at = Self.onScreen(event), dx = at.x - from.x, dy = at.y - from.y
            recent = (recent + [(at, event.timestamp)]).filter { event.timestamp - $0.time < Self.recent }
            guard event.type == .leftMouseDragged else { break }
            moved = moved || hypot(dx, dy) >= Self.dragFrom
            if moved { setFrameOrigin(NSPoint(x: start.x + dx, y: start.y - dy)) }
        }
        if moved { onDropped?(Self.velocity(recent)) }
        return moved
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// How far back from letting go the pointer's moves say how fast it went: the last of them is the button let go.
    private static let recent: TimeInterval = 0.1

    /// Points a second, up positive (the events' own y goes down).
    private static func velocity(_ moves: [(at: CGPoint, time: TimeInterval)]) -> CGVector {
        guard let first = moves.first, let last = moves.last, last.time > first.time else { return .zero }
        let seconds = last.time - first.time
        return CGVector(dx: (last.at.x - first.at.x) / seconds, dy: (first.at.y - last.at.y) / seconds)
    }

    /// From the event itself, in the screen's own coordinates: `locationInWindow` shifts as the window follows the pointer.
    private static func onScreen(_ e: NSEvent) -> CGPoint { e.cgEvent?.location ?? .zero }

    static func floating(_ content: NSView, radius: CGFloat, fullScreen: Bool) -> StripPanel {
        let panel = StripPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.apply(fullScreen: fullScreen)
        panel.contentView = ground(content, radius: radius)
        return panel
    }

    /// For one that takes the keys (a card): a key borderless window is drawn square, its shadow and rim at the corners
    /// past the rounded ground. A titled one with its bar see-through and empty is rounded as windows are.
    func takesKeys() {
        styleMask.insert([.titled, .fullSizeContentView])
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    /// Off: it stays out of a full-screen app's Space (a talk, a film).
    func apply(fullScreen: Bool) {
        collectionBehavior = [
            .canJoinAllSpaces, fullScreen ? .fullScreenAuxiliary : .fullScreenNone, .stationary, .ignoresCycle
        ]
    }

    /// Liquid Glass where there is, the popover card before.
    private static func ground(_ content: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        return FloatingCard(content, radius: radius)
    }
}

/// The strip's own ground, between its tiles: it moves the strip too, and a click on it (the handle of a hidden strip) is its own.
final class StripRow: NSStackView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    /// Two fingers swept over it, on a trackpad.
    var onSwipe: ((StripWay) -> Void)?
    private var swept = CGVector.zero, flung = false
    /// The pointer is on the strip, its tiles included.
    var pointerOn = false
    private var anyApp: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        if (window as? StripPanel)?.drag(from: event) == false { onClick?() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        anyApp = retracked(anyApp, .activeAlways)
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    /// A trackpad's scroll over the strip (a tile's goes on up to here) adds up while the fingers move, and sends it off
    /// as soon as it's far enough: once a gesture. The coasting after it is no gesture, nor a mouse wheel's clicks.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swept = .zero
            flung = false
        }
        guard !flung else { return }
        swept.dx += event.scrollingDeltaX
        swept.dy += event.scrollingDeltaY
        guard let way = StripModel.swipe(dx: swept.dx, dy: swept.dy, natural: event.isDirectionInvertedFromDevice)
        else {
            return
        }
        flung = true
        onSwipe?(way)
    }
    /// With Kelp behind, the click that reaches a window goes only to a view that takes a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A workspace on the strip: its project's tile with its state in the corner, and in a pill what its agent asks.
final class StripButton: PointerControl {
    static let stripHeight: CGFloat = 40
    private static let height: CGFloat = 32, tile: CGFloat = 24, markInset: CGFloat = 2, wordsWidth: CGFloat = 240

    var onClick: (() -> Void)?
    var onMenu: (() -> NSMenu)?
    var onHover: ((Bool) -> Void)?
    private let icon = NSImageView(), mark = StatusMark(size: 12), label = NSTextField(labelWithString: "")
    /// Its branch's CI, in a bite out of the tile's other right corner.
    private var ciMark: NSView?, ciState: CIRuns.State?
    private let glow = EdgeGlow(radius: StripButton.height / 2, spread: 2, strength: 0.35)
    private var trailing: NSLayoutConstraint?
    private var anyApp: NSTrackingArea?
    private let bite = CAShapeLayer()
    /// The glow its state wants, kept while a flash shows another for a moment.
    private var calls: (color: NSColor?, breathing: Bool) = (nil, false)
    private var flashing: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Self.height / 2
        clipsToBounds = false   // a closed tile is a circle, and its corner would cut the mark in two
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        for v in [glow, icon, label, mark] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        notch(ci: false)
        let closed = trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        trailing = closed
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height), closed,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.tile),
            icon.heightAnchor.constraint(equalToConstant: Self.tile),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.gapWide),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.wordsWidth),
            mark.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -Self.markInset),
            mark.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -Self.markInset)
        ])
        pin(glow)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The mark sits in a bite out of the tile's corner, so it reads on the strip's own glass in any theme, with no disc of its own;
    /// with CI, its mark has one out of the corner above.
    private func notch(ci: Bool) {
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown   // a project's own icon can be a 16-pt favicon
        let side = Self.tile, around = Self.markInset + 6
        let square = CGRect(x: 0, y: 0, width: side, height: side), corner = Metrics.radiusSM
        let tile = CGPath(roundedRect: square, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let round = CGRect(
            x: side - Self.markInset - around, y: Self.markInset - around, width: 2 * around, height: 2 * around)
        let hole = CGPath(ellipseIn: round, transform: nil)
        let above = CGPath(ellipseIn: round.offsetBy(dx: 0, dy: side - 2 * Self.markInset), transform: nil)
        bite.path = ci ? tile.subtracting(hole).subtracting(above) : tile.subtracting(hole)
        icon.layer?.mask = bite
    }

    func update(_ item: StripItem, open: Bool, app: AppModel) {
        if let repo = item.repo { ProjectIcon.show(repo, in: icon, app: app) }
        let status = StripModel.status(item.cell)
        // Every state has its mark in the tile's bite; working's is the spinning arc, so a strip of agents at work reads as
        // work going on, not as a row of Dock icons.
        mark.status = status
        if ciState != item.ci?.state { show(ci: item.ci?.state) }
        // A clear icon keeps the tile's shape.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            icon.layer?.backgroundColor = NSColor.fillHover.cgColor
        }
        label.isHidden = !open
        trailing?.isActive = false
        trailing = trailingAnchor.constraint(
            equalTo: open ? label.trailingAnchor : icon.trailingAnchor, constant: open ? 12 : 4)
        trailing?.isActive = true
        label.attributedStringValue = open ? words(item) : NSAttributedString()
        let calling = open && item.cell <= .failed
        calls = (calling ? (item.cell == .asks ? .systemOrange : .systemRed) : nil, calling && item.cell == .asks)
        if flashing == nil { glow.show(calls.color, breathing: calls.breathing) }
        restFill = calling ? .fillHover : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            [item.name, status.words, open ? item.words : nil, item.ci?.line].compactMap { $0 }.joined(separator: ", "))
    }

    private func show(ci state: CIRuns.State?) {
        ciState = state
        ciMark?.removeFromSuperview()
        ciMark = state.map(CIRunLook.mark)
        notch(ci: state != nil)
        guard let ciMark else { return }
        addSubview(ciMark)
        NSLayoutConstraint.activate([
            ciMark.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            ciMark.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: Self.markInset)
        ])
    }

    private func words(_ item: StripItem) -> NSAttributedString {
        // In the string itself: attributed text doesn't take the field's truncation, and would stop dead at a word.
        let cut = NSMutableParagraphStyle()
        cut.lineBreakMode = .byTruncatingTail
        func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: cut])
        }
        let title = NSMutableAttributedString(
            attributedString: text(item.name, .ui(TextSize.row, weight: .medium), .labelColor))
        let color: NSColor =
            switch item.cell {
            case .asks: .textOrange
            case .failed: .textRed
            case .working, .done: .secondaryLabelColor
            }
        title.append(text("  " + StripModel.brief(item.words ?? ""), .ui(TextSize.row), color))
        return title
    }

    /// News on this tile: its glow lights up in the news's colour for a moment, as Needs You does, then shows its state
    /// again. Finished work lights in the text's colour, faintly.
    func flash(_ cell: DockFace.Cell) {
        let color: NSColor = cell == .asks ? .systemOrange : cell == .failed ? .systemRed : .labelColor
        flashing?.invalidate()
        glow.show(color, breathing: false, faint: cell == .done)
        flashing = Timer.scheduledTimer(withTimeInterval: Motion.flash, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {   // the main run loop's timer
                guard let self else { return }
                self.flashing = nil
                self.glow.show(self.calls.color, breathing: self.calls.breathing)
            }
        }
    }

    override func clicked() { onClick?() }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
    /// A tile is most of the strip, so a drag from one moves it; held still and let go, it's a click.
    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? StripPanel else { return super.mouseDown(with: event) }
        fadeBackground(to: .fillSelected, held: true)
        let moved = panel.drag(from: event)
        refreshPointer()
        guard !moved else { return }
        pressBounce()
        clicked()
    }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    /// Kelp is behind and stays there: the first click is the click, and the pointer answers with it inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole tile is the button. A click over its icon or words would otherwise go to them, which don't take a first click,
    /// and with Kelp behind it would be lost.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        anyApp = retracked(anyApp, .activeAlways)
    }
}

/// What a tile says under the pointer: its workspace and how each of its agents is, over the strip (under it at the top of a
/// screen). It takes no clicks: the pointer goes through to the strip.
@MainActor
final class StripTip {
    /// Agents listed by name; past them, how many more.
    static let listed = 5
    private let name = NSTextField(labelWithString: ""), agents = NSTextField(labelWithString: "")
    private lazy var panel: StripPanel = {
        name.font = .ui(TextSize.row, weight: .medium)
        agents.font = .ui(TextSize.caption)
        agents.textColor = .secondaryLabelColor
        for f in [name, agents] {
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = f === agents ? Self.listed + 1 : 1
            f.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        }
        let stack = NSStackView(views: [name, agents])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.gapWide + 2, bottom: Metrics.gap, right: Metrics.gapWide + 2)
        let made = StripPanel.floating(stack, radius: Metrics.radiusMD, fullScreen: true)
        made.ignoresMouseEvents = true
        return made
    }()

    var isShowing: Bool { panel.isVisible }

    func show(_ item: StripItem, over tile: NSRect, below: Bool) {
        name.stringValue = item.name
        agents.stringValue = ([Self.lines(item.agents)] + [item.ci?.line].compactMap { $0 }).joined(separator: "\n")
        let content = panel.contentView
        content?.layoutSubtreeIfNeeded()
        let size = content?.fittingSize ?? .zero
        var frame = NSRect(
            x: tile.midX - size.width / 2, y: below ? tile.minY - 12 - size.height : tile.maxY + 12, width: size.width,
            height: size.height)
        if let area = NSScreen.screens.first(where: { $0.frame.intersects(tile) })?.visibleFrame {
            frame.origin.x = min(max(frame.minX, area.minX + 4), area.maxX - size.width - 4)
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    static func lines(_ agents: [String]) -> String {
        let more = agents.count - listed
        return (agents.prefix(listed) + (more > 0 ? [String(localized: "and \(more) more")] : [])).joined(
            separator: "\n")
    }
}
