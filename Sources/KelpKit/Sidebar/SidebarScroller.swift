import AppKit
import DesignKit

/// The scroll view of the sidebar's list, with a thin knob and no track, because the system's wide, light overlay knob
/// lay across the right edge of the project cards. The knob stands in the room to the right of the cards when the
/// sidebar has some (`SidebarController.gutter`), or else on the cards' own right margin, clear of their text.
final class SidebarScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        verticalScroller = SidebarScroller()
        hasVerticalScroller = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Always overlay, because with "Always show scroll bars" a legacy scroller took 15 pt from the cards and drew an
    /// empty track.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = newValue == .legacy ? .overlay : newValue }
    }
}

final class SidebarScroller: NSScroller {
    override static var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    /// Draws the knob as a 4 pt capsule centred half a wide gap in from the edge. That puts it in the middle of the
    /// 8 pt gap between the cards and the floating sidebar's border, or of the cards' right margin when docked.
    override func drawKnob() {
        let knob = rect(for: .knob).insetBy(dx: 0, dy: 2), width: CGFloat = 4
        let capsule = NSRect(
            x: bounds.maxX - Metrics.gapWide / 2 - width / 2, y: knob.minY, width: width, height: knob.height)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: width / 2, yRadius: width / 2).fill()
    }
}
