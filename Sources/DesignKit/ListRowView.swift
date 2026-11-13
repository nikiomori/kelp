import AppKit

/// A cell that shows something while the pointer is over its row (VS Code's inline actions).
@MainActor
public protocol Hoverable: AnyObject { func setHover(_ on: Bool) }

/// A row of an inspector list: the system's selection colour on a rounded rect inset 6 from the sides and 1 from its
/// neighbours, and the pointer passed on to a `Hoverable` cell. The selection pill is the sidebar's alone.
/// A palette's row (Spotlight's) asks for its own inset and corner, a fixed selection colour that stays emphasised in a
/// panel that isn't key, the pointer even while another window has the keyboard, and which rows light up at all.
/// Rows that belong together sit on a `Card`, the sidebar's look for a project: one quiet shape under all of them.
@MainActor
public final class ListRowView: NSTableRowView {
    /// Its part of a card: the first row rounds its top, the last its bottom; `fill` the card's colour.
    public struct Card: Equatable {
        public var first: Bool, last: Bool, fill: NSColor
        public init(first: Bool, last: Bool, fill: NSColor = .fillRest) {
            self.first = first
            self.last = last
            self.fill = fill
        }
    }
    /// Room a card's first row takes over its content, and its last under: the card's edge 2 pt from the row's, the
    /// selection 4 pt inside the card (the sidebar's spacing). A list adds it to those rows' heights and cells.
    public static let cardPad: CGFloat = 6
    public var card: Card? {
        didSet {
            guard card != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }
    private var area: NSTrackingArea?
    private let inset: CGFloat, radius: CGFloat, selection: NSColor?, tracking: NSTrackingArea.Options
    private let lights: (ListRowView) -> Bool

    public init(
        inset: CGFloat = 6, radius: CGFloat = Metrics.radiusSM, selection: NSColor? = nil,
        tracking: NSTrackingArea.Options = .activeInKeyWindow, lights: @escaping (ListRowView) -> Bool = { _ in true }
    ) {
        self.inset = inset
        self.radius = radius
        self.selection = selection
        self.tracking = tracking
        self.lights = lights
        super.init(frame: .zero)
    }
    public required init?(coder: NSCoder) { fatalError() }

    override public var isEmphasized: Bool {
        get { selection != nil || super.isEmphasized }
        set { super.isEmphasized = newValue }
    }
    /// Under the pointer: the selection's shape in the hover grey, faded in and out. A layer, not a view: a row view's
    /// subviews are its cells (`view(atColumn:)` counts them).
    private let hoverFill = CALayer()
    private var hovering = false { didSet { showHover() } }
    override public var isSelected: Bool { didSet { showHover() } }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        area = retracked(area, tracking)
    }
    override public func mouseEntered(with event: NSEvent) { setHovering(true) }
    override public func mouseExited(with event: NSEvent) { setHovering(false) }
    private func setHovering(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        (subviews.first { $0 is Hoverable } as? Hoverable)?.setHover(on)
    }

    /// A list scrolled under a still pointer: rows coming under it get an "entered", the ones leaving often no "exited",
    /// so several stayed lit at once. Each scroll asks again where the pointer is; a reused row starts unlit.
    private var scrollWatch: NSObjectProtocol?
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollWatch { NotificationCenter.default.removeObserver(scrollWatch) }
        scrollWatch = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else {
            setHovering(false)
            return
        }
        scrollWatch = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPointer() }   // queue: .main
        }
    }
    override public func prepareForReuse() {
        super.prepareForReuse()
        setHovering(false)
    }
    private func recheckPointer() {
        guard let window else { return }
        setHovering(
            (tracking.contains(.activeAlways) || window.isKeyWindow)
                && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func showHover() {
        wantsLayer = true
        guard let layer else { return }
        if hoverFill.superlayer == nil {
            hoverFill.cornerRadius = radius
            hoverFill.cornerCurve = .continuous
            layer.insertSublayer(hoverFill, at: 0)
        }
        hoverFill.frame = pill
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = hovering && !isSelected && lights(self) ? NSColor.fillHover.cgColor : nil
        }
        hoverFill.animate("backgroundColor", to: color)
    }
    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // the fill follows the row's size, it doesn't slide there
        hoverFill.frame = pill
        CATransaction.commit()
        // On a card's first or last row the cell keeps clear of the pad, so its text sits in the middle of its pill.
        guard let card else { return }
        let top = card.first ? Self.cardPad - 1 : 0, bottom = card.last ? Self.cardPad - 1 : 0
        for cell in subviews {
            cell.frame = NSRect(
                x: cell.frame.minX, y: top, width: cell.frame.width, height: bounds.height - top - bottom)
        }
    }
    override public func drawSelection(in rect: NSRect) {
        (selection
            ?? (isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor))
            .setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
    }

    /// The selection's and the pointer's shape: on a card, 4 pt inside it.
    private var pill: NSRect {
        guard let card else { return bounds.insetBy(dx: inset, dy: 1) }
        let top = card.first ? Self.cardPad : 1, bottom = card.last ? Self.cardPad : 1
        return NSRect(
            x: inset + 4, y: top, width: bounds.width - 2 * (inset + 4), height: bounds.height - top - bottom)
    }

    /// Its slice of the card: a rounded rect running past the row's edge where the card goes on.
    override public func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let card else { return }
        let r = Metrics.radiusLG
        var shape = bounds.insetBy(dx: inset, dy: 0)
        shape.origin.y = card.first ? Self.cardPad - 4 : -2 * r
        shape.size.height = (card.last ? bounds.height - Self.cardPad + 4 : bounds.height + 2 * r) - shape.minY
        card.fill.setFill()
        NSBezierPath(roundedRect: shape, xRadius: r, yRadius: r).fill()
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
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x += Self.leading
        frame.size.width -= Self.leading
        return frame
    }
}
