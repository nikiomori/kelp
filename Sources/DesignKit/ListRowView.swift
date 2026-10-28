import AppKit

/// A cell that shows something while the pointer is over its row (VS Code's inline actions).
@MainActor
public protocol Hoverable: AnyObject { func setHover(_ on: Bool) }

/// A row of an inspector list: the system's selection colour on a rounded rect inset 6 from the sides and 1 from its
/// neighbours, and the pointer passed on to a `Hoverable` cell. The selection pill is the sidebar's alone.
@MainActor
public final class ListRowView: NSTableRowView {
    private var area: NSTrackingArea?

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override public func mouseEntered(with e: NSEvent) { (subviews.first as? Hoverable)?.setHover(true) }
    override public func mouseExited(with e: NSEvent) { (subviews.first as? Hoverable)?.setHover(false) }

    override public func drawSelection(in r: NSRect) {
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: Metrics.radiusSM, yRadius: Metrics.radiusSM).fill()
    }
}
