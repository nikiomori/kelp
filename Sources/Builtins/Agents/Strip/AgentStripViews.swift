import AppKit
import Core
import DesignKit
import KelpKit

/// A panel that takes clicks and a typed reply and leaves the active app active. It stays up with Kelp behind, on every Space, and
/// at a level under the Dock's.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Moved by the pointer, and let go.
    var onDropped: (() -> Void)?
    /// What a hand trembles by: less than this is a click.
    private static let dragFrom: CGFloat = 4

    /// Follows the pointer until the button is let go; says if it went anywhere, as if not this was a click.
    func drag(from down: NSEvent) -> Bool {
        let start = frame.origin, from = Self.onScreen(down)
        var moved = false
        while let event = nextEvent(matching: [.leftMouseUp, .leftMouseDragged]), event.type == .leftMouseDragged {
            let at = Self.onScreen(event), dx = at.x - from.x, dy = at.y - from.y
            moved = moved || hypot(dx, dy) >= Self.dragFrom
            if moved { setFrameOrigin(NSPoint(x: start.x + dx, y: start.y - dy)) }
        }
        if moved { onDropped?() }
        return moved
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
    private let glow = EdgeGlow(radius: StripButton.height / 2, spread: 2, strength: 0.35)
    private var trailing: NSLayoutConstraint?
    private var anyApp: NSTrackingArea?
    private let bite = CAShapeLayer(), rounded = CAShapeLayer()

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
        notch()
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

    /// The mark sits in a bite out of the tile's corner, so it reads on the strip's own glass in any theme, with no disc of its own.
    private func notch() {
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown   // a project's own icon can be a 16-pt favicon
        let side = Self.tile, around = Self.markInset + 6
        let square = CGRect(x: 0, y: 0, width: side, height: side), corner = Metrics.radiusSM
        let tile = CGPath(roundedRect: square, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let round = CGRect(
            x: side - Self.markInset - around, y: Self.markInset - around, width: 2 * around, height: 2 * around)
        let hole = CGPath(ellipseIn: round, transform: nil)
        bite.path = tile.subtracting(hole)
        icon.layer?.mask = bite
        rounded.path = tile
    }

    func update(_ item: StripItem, open: Bool, app: AppModel) {
        if let repo = item.repo { ProjectIcon.show(repo, in: icon, app: app) }
        let status = StripModel.status(item.cell)
        // Working is a tile's own state: no mark. A mark is something to look at, and only then is the tile cut for it.
        mark.status = item.cell == .working ? nil : status
        icon.layer?.mask = item.cell == .working ? rounded : bite
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
        let calls = open && item.cell <= .failed
        glow.show(
            calls ? (item.cell == .asks ? .systemOrange : .systemRed) : nil, breathing: calls && item.cell == .asks)
        restFill = calls ? .fillHover : nil
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            [item.name, status.words, open ? item.words : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private func words(_ item: StripItem) -> NSAttributedString {
        // In the string itself: attributed text doesn't take the field's truncation, and would stop dead at a word.
        let cut = NSMutableParagraphStyle()
        cut.lineBreakMode = .byTruncatingTail
        func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: cut])
        }
        let title = NSMutableAttributedString(attributedString: text(item.name, .ui(12, weight: .medium), .labelColor))
        let color: NSColor =
            switch item.cell {
            case .asks: .textOrange
            case .failed: .textRed
            case .working, .done: .secondaryLabelColor
            }
        title.append(text("  " + StripModel.brief(item.words ?? ""), .ui(12), color))
        return title
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
        name.font = .ui(12, weight: .medium)
        agents.font = .ui(11)
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
        agents.stringValue = Self.lines(item.agents)
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
