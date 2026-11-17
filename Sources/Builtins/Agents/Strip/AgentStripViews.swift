import AppKit
import Core
import DesignKit
import KelpKit

/// A panel that takes clicks and a typed reply without taking focus from the active app. It stays up while Kelp is
/// behind other apps, shows on every Space, and sits at a level below the Dock.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Called when the user drags the panel and lets go, with how fast it was going then. The speed is in points a
    /// second, with up positive, and zero if the hand stopped first.
    var onDropped: ((CGVector) -> Void)?
    /// Called on ⎋ while the panel has the keyboard focus, as a card does.
    var onCancel: (() -> Void)?
    /// How far a hand trembles during a click. A move shorter than this is still a click.
    private static let dragFrom: CGFloat = 4

    /// Moves the panel with the pointer until the button is let go. Returns whether it moved, because if it didn't,
    /// this was a click.
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

    /// How far back from the release the pointer's moves count toward its speed. The last of those moves is the
    /// release itself.
    private static let recent: TimeInterval = 0.1

    /// Returns the speed in points a second, with up positive, because the events' own y goes down.
    private static func velocity(_ moves: [(at: CGPoint, time: TimeInterval)]) -> CGVector {
        guard let first = moves.first, let last = moves.last, last.time > first.time else { return .zero }
        let seconds = last.time - first.time
        return CGVector(dx: (last.at.x - first.at.x) / seconds, dy: (first.at.y - last.at.y) / seconds)
    }

    /// Returns where the event happened in screen coordinates, read from the event itself, because `locationInWindow`
    /// shifts as the window follows the pointer.
    private static func onScreen(_ event: NSEvent) -> CGPoint { event.cgEvent?.location ?? .zero }

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
        panel.contentView = FloatingCard.ground(content, radius: radius)
        return panel
    }

    /// Readies a panel that takes the keyboard focus, as a card does. A borderless key window is drawn square, with its
    /// shadow and rim at the corners past the rounded ground. A titled window with a clear, empty title bar is rounded
    /// as windows are.
    func takesKeys() {
        styleMask.insert([.titled, .fullSizeContentView])
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    /// Sets whether the panel shows over full-screen apps. When off, it stays out of a full-screen app's Space, as
    /// during a talk or a film.
    func apply(fullScreen: Bool) {
        collectionBehavior = [
            .canJoinAllSpaces, fullScreen ? .fullScreenAuxiliary : .fullScreenNone, .stationary, .ignoresCycle
        ]
    }

    /// Shows the panel at `frame`. It starts offset by `by` and slides into place while it fades in.
    func slideIn(to frame: NSRect, by: CGVector) {
        setFrame(frame.offsetBy(dx: by.dx, dy: by.dy), display: false)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.appear)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
            animator().alphaValue = 1
        }
    }

    /// Fades the panel out and then takes it off the screen, unless `back` says it was shown again meanwhile.
    func fadeOut(unless back: @escaping @MainActor () -> Bool = { false }) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.fast)
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { if !back() { self.orderOut(nil) } }   // AppKit runs it on the main thread
        }
    }
}

/// The strip's own background between its tiles. A drag on it moves the strip too, and a click on it, as on the
/// handle of a hidden strip, has its own action (`onClick`).
final class StripRow: NSStackView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    /// Called when two fingers swipe over the strip on a trackpad.
    var onSwipe: ((StripWay) -> Void)?
    private var swept = CGVector.zero, flung = false
    /// Whether the pointer is on the strip, its tiles included.
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
    /// Adds up a trackpad's scroll over the strip while the fingers move, and sends a swipe once per gesture, as soon
    /// as the scroll is far enough. A scroll over a tile is passed up to here. The coasting after a gesture isn't a
    /// swipe, and neither are a mouse wheel's clicks.
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
    /// While Kelp is behind other apps, a click reaches only a view that takes a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A workspace on the strip. It shows the project's tile with the agent's state in the corner, and, when opened into
/// a pill, what the agent asks.
final class StripButton: PointerControl {
    static let stripHeight: CGFloat = 40
    private static let height: CGFloat = 32, tile: CGFloat = 24, markInset: CGFloat = 2, wordsWidth: CGFloat = 240

    var onMenu: (() -> NSMenu)?
    var onHover: ((Bool) -> Void)?
    private let icon = NSImageView(), mark = StatusMark(size: 12), label = NSTextField(labelWithString: "")
    /// The CI mark of the agent's branch, in a bite out of the tile's top right corner.
    private var ciMark: NSView?, ciShown: String?
    private let glow = EdgeGlow(radius: StripButton.height / 2, spread: 2, strength: 0.35)
    private var trailing: NSLayoutConstraint?
    private var anyApp: NSTrackingArea?
    private let bite = CAShapeLayer()
    /// The glow the tile's state calls for, kept while a flash shows another glow for a moment.
    private var calls: (color: NSColor?, breathing: Bool) = (nil, false)
    private var flashing: Timer?
    /// The item and open state the tile last showed.
    private var shown: (item: StripItem, open: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Self.height / 2
        clipsToBounds = false   // a closed tile is a circle, and clipping to it would cut the mark in two
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

    /// Cuts a bite out of the tile's corner for the state mark, so the mark reads on the strip's glass in any theme
    /// without a disc of its own. With CI, a second bite out of the corner above holds the CI mark.
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
        // The fill behind the icon keeps the tile's shape when a project's icon has a clear background.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            icon.layer?.backgroundColor = NSColor.fillHover.cgColor
        }
        // Nothing changed for this tile. Swapping its constraint anyway would lay the strip out again for every agent's
        // news.
        guard shown?.item != item || shown?.open != open else { return }
        shown = (item, open)
        let status = StripModel.status(item.cell)
        // Every state has its mark in the tile's bite. The working state's mark is the spinning arc, so a strip of
        // working agents reads as work going on, not as a row of Dock icons.
        mark.status = status
        if ciShown != item.ci?.key { show(ci: item.ci) }
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
            [item.name, status.words, open ? item.words : nil, item.ci?.tip].compactMap { $0 }.joined(separator: ", "))
    }

    /// Shows the branch's CI mark as the sidebar shows it, at 12 pt, drawn by the built-in that owns CI
    /// (`RowMark.view`).
    private func show(ci: RowMark?) {
        ciShown = ci?.key
        ciMark?.removeFromSuperview()
        ciMark = ci?.view?()
        notch(ci: ciMark != nil)
        guard let ciMark else { return }
        addSubview(ciMark)
        NSLayoutConstraint.activate([
            ciMark.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            ciMark.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: Self.markInset)
        ])
    }

    private func words(_ item: StripItem) -> NSAttributedString {
        // The string itself says to truncate, because attributed text ignores the field's line break mode and
        // would stop dead at a word.
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

    /// Flashes the tile for news. Its glow lights up in the news's colour for a moment, as Needs You does, then goes
    /// back to its state's glow. Finished work lights up faintly, in the text's colour.
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

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
    /// A tile is most of the strip, so a drag from a tile moves the strip. A press held still and let go is a click.
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
    /// Kelp is behind other apps and stays there, so the first click counts as the click, and the tile reacts to the
    /// pointer while Kelp is inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole tile is the button. A click over its icon or words would otherwise go to those views, which don't take
    /// a first click, so with Kelp behind the click would be lost.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        anyApp = retracked(anyApp, .activeAlways)
    }
}

/// The tip for the tile under the pointer, with its workspace and the state of each of its agents. It shows above the
/// strip, or below it when the strip is at the top of a screen. It takes no clicks, so the pointer goes through to the
/// strip.
@MainActor
final class StripTip {
    /// How many agents the tip lists by name. Past them, it says how many more there are.
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
        agents.stringValue = ([Self.lines(item.agents)] + [item.ci?.tip].compactMap { $0 }).joined(separator: "\n")
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
