import AppKit
import DesignKit

/// Color in a project's row menu: a dot for each colour, as Finder's tags in its menus, so a pick is one click. The dot
/// under the pointer shows on the project's own row what it would do.
@MainActor
final class ColorSwatches: NSView {
    private static let side: CGFloat = 18, gap: CGFloat = 4, inset: CGFloat = 12, height: CGFloat = 26   // a dot lines up with the items' text

    private let colors: [ProjectColor?] = [nil] + ProjectColor.allCases
    private var swatches: [Swatch] = []
    private let previewing: (ProjectColor?) -> Void, left: () -> Void
    let pick: (ProjectColor?) -> Void
    /// The dot under the pointer. The row is one area, the nearest dot taking the gaps between: a dot of its own each, the
    /// preview went back to the saved colour over every gap, and the row flashed it between two dots.
    private var under: Int? {
        didSet {
            guard under != oldValue else { return }
            for (index, swatch) in swatches.enumerated() { swatch.hovering = index == under }
            if let under { previewing(colors[under]) } else { left() }
        }
    }

    /// `previewing` is told the colour under the pointer, `left` that the pointer has gone from the dots.
    init(
        chosen: ProjectColor?, previewing: @escaping (ProjectColor?) -> Void, left: @escaping () -> Void,
        pick: @escaping (ProjectColor?) -> Void
    ) {
        self.previewing = previewing
        self.left = left
        self.pick = pick
        let width = 2 * Self.inset + CGFloat(colors.count) * Self.side + CGFloat(colors.count - 1) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        for (index, color) in colors.enumerated() {
            let frame = NSRect(
                x: Self.inset + CGFloat(index) * (Self.side + Self.gap), y: (Self.height - Self.side) / 2,
                width: Self.side,
                height: Self.side)
            let swatch = Swatch(frame: frame, color: color, chosen: color != nil && color == chosen)
            swatch.pressed = { [weak self] in self?.choose(index) }
            addSubview(swatch)
            swatches.append(swatch)
        }
        // Events reach a menu's views while it tracks, whatever the app's state, so not `.activeInActiveApp`.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        )
    }
    required init?(coder: NSCoder) { fatalError() }

    private func index(at event: NSEvent) -> Int {
        let pointer = convert(event.locationInWindow, from: nil).x
        let slot = Int(((pointer - Self.inset + Self.gap / 2) / (Self.side + Self.gap)).rounded(.down))
        return min(max(slot, 0), colors.count - 1)
    }
    private func choose(_ index: Int) {
        pick(colors[index])
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func mouseEntered(with event: NSEvent) { under = index(at: event) }
    override func mouseMoved(with event: NSEvent) { under = index(at: event) }
    override func mouseExited(with event: NSEvent) { under = nil }
    override func mouseUp(with event: NSEvent) { choose(index(at: event)) }
    override func rightMouseUp(with event: NSEvent) { choose(index(at: event)) }   // the menu came with a right-click, held and let go here
}

@MainActor
extension NSMenu {
    /// Color in a menu: this row of dots, or a submenu of names where VoiceOver or Full Keyboard Access is on (a view
    /// in a menu takes no keys).
    package func addColor(
        chosen: ProjectColor?, previewing: @escaping (ProjectColor?) -> Void = { _ in },
        left: @escaping () -> Void = {}, pick: @escaping (ProjectColor?) -> Void
    ) {
        guard NSWorkspace.shared.isVoiceOverEnabled || NSApp.isFullKeyboardAccessEnabled else {
            let row = addItem(withTitle: String(localized: "Color"), action: nil, keyEquivalent: "")
            row.view = ColorSwatches(chosen: chosen, previewing: previewing, left: left, pick: pick)
            return
        }
        let shades = NSMenu()
        shades.add(String(localized: "None")) { pick(nil) }.state = chosen == nil ? .on : .off
        shades.addItem(.separator())
        for color in ProjectColor.allCases {
            let item = shades.add(color.title) { pick(color) }
            item.show(color.dot)
            item.state = chosen == color ? .on : .off
        }
        add(String(localized: "Color"), submenu: shades)
    }
}

/// One dot: under the pointer it grows with a little spring and glows in its own colour. nil is None: an empty ring with
/// a stroke through it. A layer of its own, so it scales about its centre.
@MainActor
private final class Swatch: NSView {
    private static let diameter: CGFloat = 14, grown: CGFloat = 16
    private let color: ProjectColor?, chosen: Bool
    private let dot = CAShapeLayer(), tick = CAShapeLayer()
    var pressed: () -> Void = {}
    var hovering = false { didSet { if hovering != oldValue { grow() } } }

    init(frame: NSRect, color: ProjectColor?, chosen: Bool) {
        self.color = color
        self.chosen = chosen
        super.init(frame: frame)
        wantsLayer = true
        let side = Self.diameter, box = CGRect(x: 0, y: 0, width: side, height: side)
        dot.frame = CGRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        if color == nil {   // None
            let path = CGMutablePath()
            path.addEllipse(in: box.insetBy(dx: 0.5, dy: 0.5))
            path.move(to: CGPoint(x: 3, y: 3))
            path.addLine(to: CGPoint(x: side - 3, y: side - 3))
            dot.path = path
            dot.lineWidth = 1
        } else {
            dot.path = CGPath(ellipseIn: box, transform: nil)
            dot.shadowPath = dot.path
            dot.shadowOffset = .zero
            dot.shadowRadius = 3
            dot.shadowOpacity = 0
        }
        if chosen {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: side / 2 - 3.5, y: side / 2))
            path.addLine(to: CGPoint(x: side / 2 - 1, y: side / 2 - 2.5))
            path.addLine(to: CGPoint(x: side / 2 + 3.5, y: side / 2 + 2.5))
            tick.path = path
            tick.fillColor = nil
            tick.lineWidth = 1.8
            tick.lineCap = .round
            tick.lineJoin = .round
            dot.addSublayer(tick)
        }
        layer?.addSublayer(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(color?.title ?? String(localized: "None"))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The row takes the pointer (ColorSwatches.under), the gaps between dots too.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformPress() -> Bool {
        pressed()
        return true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {   // the menu's appearance is current here
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let color {
            dot.fillColor = color.color.cgColor
            dot.shadowColor = color.color.cgColor
        } else {
            dot.fillColor = nil
            dot.strokeColor = NSColor.secondaryLabelColor.cgColor
        }
        // Dark on the pale dots of a dark menu, pale on the deep ones of a light one.
        tick.strokeColor = NSColor.windowBackgroundColor.cgColor
        CATransaction.commit()
    }

    /// 14 → 16 pt with a spring a touch past it, and its glow, over `Motion.fast`; back in two thirds of that.
    private func grow() {
        let back = Motion.fast * 2 / 3
        dot.animate(
            "shadowOpacity", to: Float(hovering && color != nil ? 0.8 : 0), duration: hovering ? Motion.fast : back)
        guard hovering else { return dot.animate("transform.scale", to: 1, duration: back) }
        let scale = Self.grown / Self.diameter
        let fromScale =
            dot.presentation()?.value(forKeyPath: "transform.scale") ?? dot.value(forKeyPath: "transform.scale")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.setValue(scale, forKeyPath: "transform.scale")
        CATransaction.commit()
        guard !Motion.reduced else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.mass = 1
        spring.stiffness = 500
        spring.damping = 20
        spring.duration = spring.settlingDuration
        spring.fromValue = fromScale
        spring.toValue = scale
        dot.add(spring, forKey: "transform.scale")
    }
}
