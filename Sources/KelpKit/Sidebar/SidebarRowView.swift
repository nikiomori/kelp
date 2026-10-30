import AppKit
import DesignKit

/// Two levels, as a Finder sidebar keeps them: a project, then what's in it 12 pt further in (an agent's mark under
/// the right half of the project's icon), workspaces as headings at the same depth as their agents.
final class SidebarOutline: NSOutlineView {
    static let lead: CGFloat = 14, step: CGFloat = 12
    /// Room over and under a row's content, where its project's card opens and closes (SidebarRowView.group).
    var pads: (Int) -> (top: CGFloat, bottom: CGFloat) = { _ in (0, 0) }
    /// No disclosure triangles: projects and workspaces fold from a chevron at their row's end (SidebarCell).
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = padded(super.frameOfCell(atColumn: column, row: row), row)
        // The content ends as far inside its card on the right as a project's icon starts on the left (SidebarRowView.band).
        let x = Self.lead + (level(forRow: row) > 0 ? Self.step : 0)
        r.origin.x = x; r.size.width = bounds.width - 8 - x
        return r
    }
    /// The row a right-click opened the menu for; `clickedRow` stays -1, see `menu(for:)`.
    private(set) var menuRow = -1
    /// The menu, without the outline NSTableView draws around the clicked row (it matched neither the pill nor the
    /// card): the row keeps its hover pill until the menu closes (`menuClosed`).
    override func menu(for event: NSEvent) -> NSMenu? {
        menuRow = row(at: convert(event.locationInWindow, from: nil))
        (rowView(atRow: menuRow, makeIfNecessary: false) as? SidebarRowView)?.menuTarget = true
        return menu
    }
    func menuClosed() {
        let row = rowView(atRow: menuRow, makeIfNecessary: false) as? SidebarRowView
        row?.menuTarget = false
        row?.recheckPointer()   // the pointer may have left it while the menu was open
        menuRow = -1
    }

    private func padded(_ r: NSRect, _ row: Int) -> NSRect {
        let p = pads(row)
        return NSRect(x: r.minX, y: r.minY + p.top, width: r.width, height: r.height - p.top - p.bottom)
    }
}

/// Like Safari's tab groups: a project with rows under it sits on a quiet card (ProjectCard), and the row you're on is a
/// raised pill (no accent colour, so the text and the status marks keep theirs). A project with nothing under it is a
/// plain row, on a card only once it was given a colour.
@MainActor
final class SidebarRowView: NSTableRowView {
    /// Where this row is in its project's card; the outline leaves room for its ends (`pads`), the pill follows its corners.
    var group: (first: Bool, last: Bool)? { didSet { if group?.first != oldValue?.first || group?.last != oldValue?.last { needsDisplay = true } } }
    private var keyWatch: [NSObjectProtocol] = []
    /// Under the pointer: the pill's shape in the hover grey, faded in and out, so a row answers before it's clicked.
    private var hovering = false { didSet { if hovering != oldValue { showHover() } } }
    private var area: NSTrackingArea?
    /// The hover pill: over the card the row draws, under the cell (a layer, so it fades rather than switches).
    private let hoverLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true   // a row closing up (SidebarController.toggle) hides what no longer fits
        hoverLayer.opacity = 0
        layer?.insertSublayer(hoverLayer, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Its menu is open (right-click): the row keeps the hover pill, as the place the menu is about, instead of the
    /// table's own outline drawn around it, which matched neither the pill nor the card.
    var menuTarget = false { didSet { if menuTarget != oldValue { showHover() } } }

    private func showHover() {
        let to: Float = (hovering || menuTarget) && !isSelected ? 1 : 0
        let from = hoverLayer.presentation()?.opacity ?? hoverLayer.opacity
        hoverLayer.opacity = to
        guard !Motion.reduced, from != to else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = Motion.fast
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hoverLayer.add(a, forKey: "fade")
    }

    /// A project's card: 4 pt over its first row and under its last (8 between cards), 4 more inside under the rows below its name.
    static func pads(_ g: (first: Bool, last: Bool)) -> (top: CGFloat, bottom: CGFloat) { (g.first ? 4 : 0, g.last ? (g.first ? 4 : 8) : 0) }

    override func drawBackground(in r: NSRect) {
        let pad = group.map(Self.pads) ?? (top: 0, bottom: 0)
        // In a card the pill is 4 pt inside it, its corners following the card's (9 − 4); a row on its own gets a pill
        // where its card would be.
        var pill = group == nil ? band(6).insetBy(dx: 0, dy: 1) : band(10).insetBy(dx: 0, dy: 2)
        pill.origin.y += pad.top; pill.size.height -= pad.top + pad.bottom
        let path = NSBezierPath(roundedRect: pill, xRadius: group == nil ? 9 : 5, yRadius: group == nil ? 9 : 5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        hoverLayer.path = path.cgPath
        hoverLayer.fillColor = NSColor.fillHover.cgColor   // drawing runs in the row's appearance
        CATransaction.commit()
        guard isSelected else { return }   // the outline draws no selection of its own (selectionHighlightStyle .none)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, key = window?.isKeyWindow ?? true
        NSGraphicsContext.saveGraphicsState()
        if !dark && key {   // light: white lifted off the grey card by a hairline shadow; dark: lighter is nearer, no shadow
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .init(width: 0, height: -0.5)
            shadow.set()
        }
        // Another window in front: the pill stays, quieter, as Finder's selection goes grey.
        NSColor.white.withAlphaComponent(dark ? (key ? 0.12 : 0.055) : (key ? 1 : 0.6)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {   // the pill alone is 1.5:1 to its card
            (dark ? NSColor.white.withAlphaComponent(0.35) : NSColor.black.withAlphaComponent(0.25)).setStroke()
            let edge = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: group == nil ? 8.5 : 4.5, yRadius: group == nil ? 8.5 : 4.5)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
    /// The row inset by `inset` on the left and 8 pt less on the right: past the sidebar's right edge come the divider
    /// and the editor area's own margin, so a card leaves the same gap to the window's edge and to the editor (8 pt).
    private func band(_ inset: CGFloat) -> NSRect { Self.band(bounds, inset) }
    static func band(_ r: NSRect, _ inset: CGFloat) -> NSRect {
        NSRect(x: r.minX + inset + 2, y: r.minY, width: r.width - 2 * inset + 4, height: r.height)
    }
    /// The outline sizes a row's cell once; when the row's height changes later (a project's last row gains or loses the
    /// card's foot) the cell would only stretch with it, its text off the chevron. Put it where the outline says; a row
    /// closing up keeps its cell where it was, cut off by the row's edge as it goes.
    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        guard bounds.height > 1, let o = superview as? NSOutlineView, case let row = o.row(for: self), row >= 0,
              let cell = subviews.first(where: { $0 is NSTableCellView }) else { return }
        let f = o.frameOfCell(atColumn: 0, row: row)   // only its height: mid-update a project's row comes back narrower
        cell.frame = NSRect(x: cell.frame.minX, y: f.minY - o.rect(ofRow: row).minY, width: cell.frame.width, height: f.height)
    }
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            showHover()   // the pill takes over from the hover grey
            for case let c as SidebarCell in subviews { c.selected = isSelected }   // its grey text a step lighter on the pill
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
        menuTarget = false
    }
    /// Scrolled under a still pointer, rows leaving it often get no "exited" (several stayed lit): each scroll asks again.
    private var scrollWatch: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollWatch { NotificationCenter.default.removeObserver(scrollWatch) }
        scrollWatch = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else { hovering = false; return }
        scrollWatch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPointer() }   // queue: .main
        }
    }
    func recheckPointer() {
        guard let w = window else { return }
        hovering = w.isKeyWindow && bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }
    /// The pill dims while another window is in front.
    override func viewWillMove(toWindow w: NSWindow?) {
        super.viewWillMove(toWindow: w)
        keyWatch.forEach(NotificationCenter.default.removeObserver)
        keyWatch = w == nil ? [] : [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isSelected == true { self?.needsDisplay = true } }   // queue: .main
            }
        }
    }
    override func didAddSubview(_ v: NSView) {
        super.didAddSubview(v)
        (v as? SidebarCell)?.selected = isSelected   // a cell made for a row that was already picked
    }
    /// In the sidebar's vibrant material a dark fill would come out lighter; the card and pill are drawn as they are.
    override var allowsVibrancy: Bool { false }
    /// The pill isn't the accent colour, so the cell draws as unselected (white text on it would vanish).
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A project's card: one shape under all of its rows, so it grows and shrinks with them as the project opens or folds
/// (SidebarController.placeCards). 4 pt in from its first row's top and its last row's bottom (SidebarRowView.pads).
@MainActor
final class ProjectCard: NSView {
    /// The colour the project was given; nil: the quiet grey.
    var tint: NSColor? { didSet { if tint != oldValue { fadeBackground(to: fill) } } }
    private var fill: NSColor { tint.map(NSColor.fillTint) ?? .fillRest }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {   // the appearance is current here: the fill follows light and dark
        layer?.cornerRadius = 9
        layer?.backgroundColor = fill.cgColor
    }
    /// In the sidebar's vibrant material a dark fill would come out lighter; the card is drawn as it is.
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }   // the rows over it take the clicks
}
