import AppKit
import DesignKit

/// Color in a project's row menu: a dot for each colour, as Finder's tags in its menus, so a pick is one click. The dot
/// under the pointer shows on the project's own row what it would do.
@MainActor
final class ColorSwatches: NSView {
    private static let side: CGFloat = 18, gap: CGFloat = 4, inset: CGFloat = 12, height: CGFloat = 26   // a dot lines up with the items' text

    let pick: (ProjectColor?) -> Void

    /// `previewing` is told the colour under the pointer, `left` that the pointer has gone from the dots.
    init(chosen: ProjectColor?, previewing: @escaping (ProjectColor?) -> Void, left: @escaping () -> Void, pick: @escaping (ProjectColor?) -> Void) {
        self.pick = pick
        let colors: [ProjectColor?] = [nil] + ProjectColor.allCases
        let width = 2 * Self.inset + CGFloat(colors.count) * Self.side + CGFloat(colors.count - 1) * Self.gap
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        for (i, c) in colors.enumerated() {
            let frame = NSRect(x: Self.inset + CGFloat(i) * (Self.side + Self.gap), y: (Self.height - Self.side) / 2, width: Self.side, height: Self.side)
            let s = Swatch(frame: frame, color: c, chosen: c != nil && c == chosen)
            s.entered = { previewing(c) }
            s.exited = left
            s.pressed = { [weak self] in
                pick(c)
                self?.enclosingMenuItem?.menu?.cancelTracking()
            }
            addSubview(s)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One dot, a little bigger under the pointer. nil is None: an empty ring with a stroke through it.
@MainActor
private final class Swatch: NSView {
    private let color: ProjectColor?, chosen: Bool
    var entered: () -> Void = {}, exited: () -> Void = {}, pressed: () -> Void = {}
    private var hovering = false { didSet { needsDisplay = true } }

    init(frame: NSRect, color: ProjectColor?, chosen: Bool) {
        self.color = color; self.chosen = chosen
        super.init(frame: frame)
        // Events reach a menu's views while it tracks, whatever the app's state, so not `.activeInActiveApp`.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(color?.title ?? String(localized: "None"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { hovering = true; entered() }
    override func mouseExited(with e: NSEvent) { hovering = false; exited() }
    override func mouseUp(with e: NSEvent) { pressed() }
    override func rightMouseUp(with e: NSEvent) { pressed() }   // the menu came with a right-click, held and let go here
    override func accessibilityPerformPress() -> Bool { pressed(); return true }

    override func draw(_ dirty: NSRect) {
        let d: CGFloat = hovering ? 16 : 14
        let dot = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        guard let color else {
            NSColor.secondaryLabelColor.setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            let stroke = NSBezierPath()
            stroke.move(to: NSPoint(x: dot.minX + 3, y: dot.minY + 3))
            stroke.line(to: NSPoint(x: dot.maxX - 3, y: dot.maxY - 3))
            stroke.lineWidth = 1
            stroke.stroke()
            return
        }
        color.color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        guard chosen else { return }
        NSColor.windowBackgroundColor.setStroke()   // dark on the pale dots of a dark menu, pale on the deep ones of a light one
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: dot.midX - 3.5, y: dot.midY))
        tick.line(to: NSPoint(x: dot.midX - 1, y: dot.midY - 2.5))
        tick.line(to: NSPoint(x: dot.midX + 3.5, y: dot.midY + 2.5))
        tick.lineWidth = 1.8
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        tick.stroke()
    }
}
