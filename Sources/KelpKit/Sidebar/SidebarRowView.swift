import AppKit
import DesignKit

/// A project, then its chats and groups in the same two columns (the slot under the project's icon, the name under its
/// name: the card says what's in it), then a group's chats 12 pt further in.
final class SidebarOutline: NSOutlineView {
    static let lead: CGFloat = 14, step: CGFloat = 12
    /// Room over and under a row's content, where its project's card opens and closes (SidebarRowView.group).
    var pads: (Int) -> (top: CGFloat, bottom: CGFloat) = { _ in (0, 0) }
    /// No disclosure triangles: projects and groups fold from the chevron their slot shows under the pointer (SidebarCell).
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var cellFrame = padded(super.frameOfCell(atColumn: column, row: row), row)
        // The content ends as far inside its card on the right as a project's icon starts on the left (SidebarRowView.band).
        // Under a heading a step further in than the rows beside the heading: the group ends where the indent does.
        let left = Self.lead + (level(forRow: row) >= 2 ? Self.step : 0)
        cellFrame.origin.x = left
        cellFrame.size.width = bounds.width - 8 - left
        return cellFrame
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

    private func padded(_ cellFrame: NSRect, _ row: Int) -> NSRect {
        let pad = pads(row)
        return NSRect(
            x: cellFrame.minX, y: cellFrame.minY + pad.top, width: cellFrame.width,
            height: cellFrame.height - pad.top - pad.bottom)
    }
}

/// Like Safari's tab groups: a project with rows under it sits on a quiet card (ProjectCard), and the row you're on is a
/// raised pill (no accent colour, so the text and the status marks keep theirs). A project with nothing under it is a
/// plain row, on a card only when its colour fills one.
@MainActor
final class SidebarRowView: NSTableRowView {
    /// Where this row is in its project's card; the outline leaves room for its ends (`pads`), the pill follows its corners.
    var group: (first: Bool, last: Bool)? {
        didSet { if group?.first != oldValue?.first || group?.last != oldValue?.last { needsDisplay = true } }
    }
    /// Room over it that starts a server's card (`SidebarController.serverGap`): no pill there.
    var gap: CGFloat = 0 { didSet { if gap != oldValue { needsDisplay = true } } }
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
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = Motion.fast
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hoverLayer.add(fade, forKey: "fade")
    }

    /// A project's card: 4 pt over its first row and under its last (8 between cards), 4 more inside under the rows below its name.
    static func pads(_ group: (first: Bool, last: Bool)) -> (top: CGFloat, bottom: CGFloat) {
        (group.first ? 4 : 0, group.last ? (group.first ? 4 : 8) : 0)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let pad = group.map(Self.pads) ?? (top: 0, bottom: 0)
        // In a card the pill is 2 pt inside it on every side, its corners following the card's (radiusLG − 2); a row on its own gets a pill
        // where its card would be.
        var pill = group == nil ? band(6).insetBy(dx: 0, dy: 1) : band(8).insetBy(dx: 0, dy: 2)
        pill.origin.y += pad.top + gap
        pill.size.height -= pad.top + pad.bottom + gap
        let radius = Self.pillRadius(inCard: group != nil)
        let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        hoverLayer.path = path.cgPath
        hoverLayer.fillColor = NSColor.fillHover.cgColor   // drawing runs in the row's appearance
        CATransaction.commit()
        guard isSelected else { return }   // the outline draws no selection of its own (selectionHighlightStyle .none)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            key = window?.isKeyWindow ?? true
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
            let edge = NSBezierPath(
                roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
    /// A lone row's pill has a card's corners; one in a card follows the card's, 2 pt in (4 on the sides and 2 above and below looked lopsided).
    static func pillRadius(inCard: Bool) -> CGFloat { inCard ? Metrics.radiusLG - 2 : Metrics.radiusLG }
    /// The row inset by `inset` on the left and 8 pt less on the right: past the sidebar's right edge come the divider
    /// and the editor area's own margin, so a card leaves the same gap to the window's edge and to the editor (8 pt).
    private func band(_ inset: CGFloat) -> NSRect { Self.band(bounds, inset) }
    static func band(_ rect: NSRect, _ inset: CGFloat) -> NSRect {
        NSRect(x: rect.minX + inset + 2, y: rect.minY, width: rect.width - 2 * inset + 4, height: rect.height)
    }
    /// The outline sizes a row's cell once; when the row's height changes later (a project's last row gains or loses the
    /// card's foot) the cell would only stretch with it, its text off the chevron. Put it where the outline says; a row
    /// closing up keeps its cell where it was, cut off by the row's edge as it goes.
    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        guard bounds.height > 1, let outline = superview as? NSOutlineView, case let row = outline.row(for: self),
            row >= 0,
            let cell = subviews.first(where: { $0 is NSTableCellView })
        else { return }
        let cellFrame = outline.frameOfCell(atColumn: 0, row: row)   // only its height: mid-update a project's row comes back narrower
        cell.frame = NSRect(
            x: cell.frame.minX, y: cellFrame.minY - outline.rect(ofRow: row).minY, width: cell.frame.width,
            height: cellFrame.height)
    }
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            showHover()   // the pill takes over from the hover grey
            for case let cell as SidebarCell in subviews { cell.selected = isSelected }   // its grey text a step lighter on the pill
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area = retracked(area, .activeInActiveApp)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
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
        guard window != nil, let clip = enclosingScrollView?.contentView else {
            hovering = false
            return
        }
        scrollWatch = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPointer() }   // queue: .main
        }
    }
    func recheckPointer() {
        guard let window else { return }
        hovering = window.isKeyWindow && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    /// The pill dims while another window is in front.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        keyWatch.forEach(NotificationCenter.default.removeObserver)
        keyWatch =
            newWindow == nil
            ? []
            : [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { if self?.isSelected == true { self?.needsDisplay = true } }   // queue: .main
                }
            }
    }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SidebarCell)?.selected = isSelected   // a cell made for a row that was already picked
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
    /// What it shows: `color` as a fill, else the quiet grey unless it's `plain`, a project's own row with nothing under it;
    /// `remote`, a server's card: marked as elsewhere the way Settings › Appearance › Servers says.
    struct Look: Equatable {
        var color: ProjectColor?
        var plain: Bool
        var remote: ServerLook?
    }
    var look = Look(color: nil, plain: false) {
        didSet {
            guard look != oldValue else { return }
            fadeBackground(to: fill)
            needsDisplay = true
        }
    }
    private var fill: NSColor? {
        let base: NSColor? = look.color.map { .fillTint($0.color) } ?? (look.plain ? nil : .fillRest)
        switch look.remote {
        case .stripes?: return Self.stripes(over: base)
        case .sparse?: return Self.stripes(over: base, side: 9)
        // Stripes of their own that fade (`fading`), or only under the server's icon: a quiet card holds the rest together.
        case .fade?, .icon?: return .fillRest
        case nil: return base
        }
    }
    /// ServerLook.fade: the stripes by the server's icon, gone before the names and meters.
    private var fading: CAShapeLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true   // the fading stripes keep to its corners
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {   // the appearance is current here: the fill follows light and dark
        layer?.cornerRadius = Metrics.radiusLG
        layer?.backgroundColor = fill?.cgColor
        layer?.borderWidth = look.remote == .sparse ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.cgColor
        showFading()
    }

    private func showFading() {
        guard look.remote == .fade else {
            fading?.removeFromSuperlayer()
            fading = nil
            return
        }
        // Lines, not the pattern colour: a pattern drew nothing in a layer of its own.
        let stripeLayer = fading ?? CAShapeLayer()
        stripeLayer.frame = bounds
        stripeLayer.path = Self.lines(in: bounds)
        stripeLayer.strokeColor = Self.stripe.cgColor
        stripeLayer.lineWidth = 1.5
        if stripeLayer.mask == nil {
            let mask = CAGradientLayer()
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            // Full over the icon's column, gone by the middle, where the names end and the meters start.
            mask.locations = [0, 0.12, 0.5]
            stripeLayer.mask = mask
        }
        // A mask doesn't follow its layer's size: set again as the card grows (setFrameSize).
        stripeLayer.mask?.frame = stripeLayer.bounds
        if fading == nil {
            layer?.insertSublayer(stripeLayer, at: 0)
            fading = stripeLayer
        }
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        guard let fading else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fading.frame = bounds
        fading.path = Self.lines(in: bounds)
        fading.mask?.frame = fading.bounds
        CATransaction.commit()
    }
    /// The stripes' lines across `rect`, as the pattern draws them.
    private static func lines(in rect: CGRect, side: CGFloat = 6) -> CGPath {
        let path = CGMutablePath()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.height))
            x += side
        }
        return path
    }

    /// Thin diagonal stripes, a step over `base`: no colour of their own, so a project's colour and the pill keep theirs.
    /// One pattern with the fill in it, the card's own ground, so it grows with the card (a layer of its own stayed at the
    /// height of a row that was still arriving).
    private static let stripe = NSColor.dynamic(
        light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.07))
    static func stripes(over base: NSColor?, side: CGFloat = 6) -> NSColor {
        let tile = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            if let base {
                base.setFill()
                rect.fill()
            }
            stripe.setStroke()
            for dx in [-side, 0, side] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: dx, y: 0))
                path.line(to: NSPoint(x: dx + side, y: side))
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        return NSColor(patternImage: tile)
    }

    /// In the sidebar's vibrant material a dark fill would come out lighter; the card is drawn as it is.
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the rows over it take the clicks
}
