import AppKit

/// A cell that shows something while the pointer is over its row (VS Code's inline actions).
@MainActor
public protocol Hoverable: AnyObject { func setHover(_ on: Bool) }

/// A row of an inspector list: the system's selection colour on a rounded rect inset 6 from the sides and 1 from its
/// neighbours, and the pointer passed on to a `Hoverable` cell. The selection pill is the sidebar's alone.
@MainActor
public final class ListRowView: NSTableRowView {
    private var area: NSTrackingArea?
    /// Under the pointer: the selection's shape in the hover grey, faded in and out. A layer, not a view: a row view's
    /// subviews are its cells (`view(atColumn:)` counts them).
    private let hoverFill = CALayer()
    private var hovering = false { didSet { showHover() } }
    override public var isSelected: Bool { didSet { showHover() } }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override public func mouseEntered(with e: NSEvent) {
        hovering = true
        (subviews.first { $0 is Hoverable } as? Hoverable)?.setHover(true)
    }
    override public func mouseExited(with e: NSEvent) {
        hovering = false
        (subviews.first { $0 is Hoverable } as? Hoverable)?.setHover(false)
    }

    private func showHover() {
        wantsLayer = true
        guard let layer else { return }
        if hoverFill.superlayer == nil {
            hoverFill.cornerRadius = Metrics.radiusSM
            hoverFill.cornerCurve = .continuous
            layer.insertSublayer(hoverFill, at: 0)
        }
        hoverFill.frame = bounds.insetBy(dx: 6, dy: 1)
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = hovering && !isSelected ? NSColor.fillHover.cgColor : nil }
        let old = hoverFill.presentation()?.backgroundColor ?? hoverFill.backgroundColor
        hoverFill.backgroundColor = color
        guard !Motion.reduced else { return }
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = old ?? NSColor.clear.cgColor
        a.toValue = color ?? NSColor.clear.cgColor
        a.duration = Motion.fast
        hoverFill.add(a, forKey: "fade")
    }
    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // the fill follows the row's size, it doesn't slide there
        hoverFill.frame = bounds.insetBy(dx: 6, dy: 1)
        CATransaction.commit()
    }
    override public func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    override public func drawSelection(in r: NSRect) {
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: Metrics.radiusSM, yRadius: Metrics.radiusSM).fill()
    }
}

/// An inspector list that is an outline: the plain style puts the disclosure triangles at the edge (the source-list
/// style had an inset of its own), so its rows start 8 pt in and line up with the panel's other rows.
@MainActor
open class ListOutlineView: NSOutlineView {
    public static let leading: CGFloat = 8

    override open func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: Self.leading, dy: 0)
    }

    override open func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        r.origin.x += Self.leading
        r.size.width -= Self.leading
        return r
    }
}
