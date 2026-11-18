import AppKit
import Core
import DesignKit

/// A sidebar row, drawn like Safari's tab groups. A project with rows under it sits on a quiet card (ProjectCard), and
/// the row you're on is a raised pill. The pill has no accent colour, so the text and the status marks keep theirs. A
/// project with nothing under it is a plain row, on a card only when its colour fills one.
@MainActor
final class SidebarRowView: NSTableRowView {
    /// Whether this row is first or last in the project's card. The outline leaves room for the card's ends (`pads`),
    /// and the pill follows the card's corners.
    var group: (first: Bool, last: Bool)? {
        didSet { if group?.first != oldValue?.first || group?.last != oldValue?.last { needsDisplay = true } }
    }
    /// Room above the row where a server's card starts (`SidebarController.serverGap`). The pill doesn't cover it.
    var gap: CGFloat = 0 { didSet { if gap != oldValue { needsDisplay = true } } }
    /// The row's own height, without the room its card's ends take: what the pill stands in. 0 while it isn't known.
    var content: CGFloat = 0 { didSet { if content != oldValue { needsDisplay = true } } }
    private var keyWatch: [NSObjectProtocol] = []
    /// True while the pointer is over the row, which then fades in the pill's shape in hover grey before any click.
    private var hovering = false { didSet { if hovering != oldValue { showHover() } } }
    private var area: NSTrackingArea?
    /// The hover pill sits over the card the row draws and under the cell, as a layer so it fades instead of switching.
    private let hoverLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true   // a row that is closing up (SidebarController.toggle) hides what no longer fits
        hoverLayer.opacity = 0
        layer?.insertSublayer(hoverLayer, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A row whose height is on its way (its project folds or opens under it) draws its pill again at each step. Left
    /// to AppKit, the picture drawn at the first step was stretched to the row's new height until the next drawing.
    override func setFrameSize(_ newSize: NSSize) {
        if newSize.height != frame.height { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    /// True while the row's right-click menu is open, so the hover pill shows what the menu is about (`menu(for:)`).
    var menuTarget = false { didSet { if menuTarget != oldValue { showHover() } } }
    /// True when the summary above the list points at this row (its count is hovered), so the row shows the hover pill.
    var lit = false { didSet { if lit != oldValue { showHover() } } }

    private func showHover() {
        // `animate` turns off the layer's own 0.25 s change, which showed again under the fade once that ended.
        hoverLayer.animate("opacity", to: Float((hovering || menuTarget || lit) && !isSelected ? 1 : 0))
    }

    /// A card takes 6 pt above a project's first row and below its last, 2 pt of it inside, so cards sit 8 pt apart.
    static func pads(_ group: (first: Bool, last: Bool)) -> (top: CGFloat, bottom: CGFloat) {
        (group.first ? 6 : 0, group.last ? 6 : 0)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let pill = Self.pill(in: bounds, group: group, gap: gap, content: content)
        let radius = Self.pillRadius(inCard: group != nil)
        let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        hoverLayer.path = path.cgPath
        hoverLayer.fillColor = NSColor.fillHover.cgColor   // drawing runs in the row's appearance
        CATransaction.commit()
        guard isSelected else { return }   // the outline draws no selection itself (selectionHighlightStyle .none)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            key = window?.isKeyWindow ?? true
        NSGraphicsContext.saveGraphicsState()
        if !dark && key {   // light: a hairline shadow lifts the pill off the card. Dark has none: lighter reads nearer
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .init(width: 0, height: -0.5)
            shadow.set()
        }
        // When another window is in front, the pill stays but quieter, as Finder's selection goes grey.
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
    /// The pill of a row that fills `bounds`. In a card, the pill is 4 pt inside the card on every side, as far as from
    /// the next pill, and its corners follow the card's (radiusLG − 4). A row on its own gets a pill where its card
    /// would be. The pill hangs from the card's top at the row's own height (`content`), so it keeps its height while
    /// a project folds or opens: the room under its row changes at once and the row takes a third of a second to
    /// follow, in which a pill cut from what the pads left shrank by that room and grew back. With less room than
    /// its height (a row arriving from nothing), it has what there is.
    static func pill(in bounds: NSRect, group: (first: Bool, last: Bool)?, gap: CGFloat, content: CGFloat) -> NSRect {
        let pad = group.map(pads) ?? (top: 0, bottom: 0), edge: CGFloat = group == nil ? 1 : 2
        var pill = band(bounds, group == nil ? 6 : 10)
        pill.origin.y += pad.top + gap + edge
        let room = bounds.height - pad.top - gap - 2 * edge
        pill.size.height = max(0, content > 0 ? min(content - 2 * edge, room) : room - pad.bottom)
        return pill
    }
    /// Returns the pill's corner radius: a card's for a row on its own, or 4 pt less (radiusSM) for a row in a card.
    static func pillRadius(inCard: Bool) -> CGFloat { inCard ? Metrics.radiusLG - 4 : Metrics.radiusLG }
    /// The row inset by `inset` on the left and 8 pt less on the right. Past the sidebar's right edge come the divider
    /// and the editor area's own margin, so a card leaves the same 8 pt gap to the window's edge and to the editor.
    private func band(_ inset: CGFloat) -> NSRect { Self.band(bounds, inset) }
    static func band(_ rect: NSRect, _ inset: CGFloat) -> NSRect {
        NSRect(x: rect.minX + inset + 2, y: rect.minY, width: rect.width - 2 * inset + 4, height: rect.height)
    }
    /// The outline sizes a row's cell once, so when the row's height changes (a project's last row gains or loses the
    /// card foot), the cell would only stretch and its text drift off the chevron. This puts the cell where the outline
    /// says, except in a closing row, whose cell stays put, cut off by its edge. The cell's width is the row's
    /// less 8 pt (`frameOfCell`), as a wider sidebar's old width let a long name run past the card, cut, not truncated.
    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        guard bounds.height > 1, let outline = superview as? NSOutlineView, case let row = outline.row(for: self),
            row >= 0,
            let cell = subviews.first(where: { $0 is NSTableCellView })
        else { return }
        // Only the cell frame's height is used, because mid-update a project's row comes back narrower.
        let cellFrame = outline.frameOfCell(atColumn: 0, row: row)
        cell.frame = NSRect(
            x: cell.frame.minX, y: cellFrame.minY - outline.rect(ofRow: row).minY,
            width: max(0, bounds.width - 8 - cell.frame.minX), height: cellFrame.height)
    }
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            if window != nil { crossfade() }   // the pill fades in and out, as the hover grey under it does
            needsDisplay = true
            showHover()   // the pill takes over from the hover grey
            // The cell's grey text turns a step lighter on the pill.
            for case let cell as SidebarCell in subviews { cell.selected = isSelected }
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
        clipsToBounds = true   // a project's row lets the glow of its icon out (SidebarController.glow)
        layer?.removeAnimation(forKey: "cascade")   // the row may have scrolled away while it was coming in
        hovering = false
        menuTarget = false
    }
    /// Rows scrolled under a still pointer often missed "exited" events and stayed lit, so each scroll rechecks it.
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
        (subview as? SidebarCell)?.selected = isSelected   // for a cell made for a row that was already selected
    }
    /// In the sidebar's vibrant material a dark fill would come out lighter; the card and pill are drawn as they are.
    override var allowsVibrancy: Bool { false }
    /// The pill isn't the accent colour, so the cell draws as unselected (white text on it would vanish).
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// How a server's card marks its projects as on another machine (Settings › Appearance › Servers): stripes under the
/// card, sparser ones in an outline, stripes by the icon fading before the text, or a striped plate under the icon.
enum ServerLook: String {
    case stripes, sparse, fade, icon
    @MainActor static func of(_ app: AppModel) -> ServerLook {
        ServerLook(rawValue: app.settings[SettingKeys.serverLook]) ?? .stripes
    }
}

/// A project's card: one shape under all its rows, growing and shrinking with them as the project opens or folds
/// (SidebarController.placeCards). It reaches 2 pt past the first and last rows and 4 pt past their pills (`pads`).
@MainActor
final class ProjectCard: NSView {
    /// What the card shows: `color` fills it, or else the quiet grey unless `plain` (a project's own row with nothing
    /// under it). `remote` marks a server's card as on another machine, as Settings › Appearance › Servers picks.
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
            showGlow()
        }
    }
    /// True while the pointer is over the project's group. A card with a colour then glows brighter, with a soft rim
    /// of its colour round it (Card style), the way the Icon style's halo glows round an icon.
    var glowing = false { didSet { if glowing != oldValue { showGlow() } } }
    private static let glowOpacity: Float = 0.6
    private static let glowRadius = Metrics.iconGlow   // the rim stays inside the list's 8 pt edges
    private var fill: NSColor? {
        let base: NSColor? = look.color.map { .fillTint($0.color) } ?? (look.plain ? nil : .fillRest)
        switch look.remote {
        case .stripes?: return Self.stripes(over: base)
        case .sparse?: return Self.stripes(over: base, side: 9)
        // These looks draw their own stripes (fading, or only under the icon), so a quiet card holds the rest together.
        case .fade?, .icon?: return .fillRest
        case nil: return base
        }
    }
    /// For ServerLook.fade, the stripes by the server's icon, which fade out before the names and meters.
    private var fading: CAShapeLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    /// Shows or hides the glow under the card. The card's translucent fill lets the glow through, so the card lights up
    /// and its edge goes soft.
    private func showGlow() {
        guard let layer else { return }
        let to: Float = glowing && look.color != nil && look.remote == nil ? Self.glowOpacity : 0
        layer.animate(
            "shadowOpacity", to: to, duration: to > 0 ? Motion.glowIn : Motion.glowOut, timing: .easeInEaseOut)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {   // the appearance is current here, so the fill follows light and dark
        layer?.cornerRadius = Metrics.radiusLG
        layer?.backgroundColor = fill?.cgColor
        layer?.masksToBounds = look.remote == .fade   // fading stripes keep inside the corners; a glow goes past them
        layer?.shadowColor = look.color?.color.cgColor
        layer?.shadowOffset = .zero
        layer?.shadowRadius = Self.glowRadius
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Metrics.radiusLG, cornerHeight: Metrics.radiusLG, transform: nil)
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
        // Draw lines, not the pattern colour, because a pattern drew nothing in a layer of its own.
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
            // Stripes show fully over the icon's column and are gone by the middle, where names end and meters start.
            mask.locations = [0, 0.12, 0.5]
            stripeLayer.mask = mask
        }
        // A mask doesn't follow its layer's size, so it is set again as the card grows (setFrameSize).
        stripeLayer.mask?.frame = stripeLayer.bounds
        if fading == nil {
            layer?.insertSublayer(stripeLayer, at: 0)
            fading = stripeLayer
        }
    }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Metrics.radiusLG, cornerHeight: Metrics.radiusLG, transform: nil)
        guard let fading else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fading.frame = bounds
        fading.path = Self.lines(in: bounds)
        fading.mask?.frame = fading.bounds
        CATransaction.commit()
    }
    /// The stripes' lines across `rect`, as the pattern draws them.
    private static func lines(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        var start = -rect.height
        while start < rect.width {
            path.move(to: CGPoint(x: start, y: 0))
            path.addLine(to: CGPoint(x: start + rect.height, y: rect.height))
            start += 6   // as `stripes`' tile
        }
        return path
    }

    /// Thin diagonal stripes, a step over `base`. They have no colour of their own, so a project's colour and the pill
    /// keep theirs. The stripes and the fill are one pattern colour, used as the card's own background, so it grows
    /// with the card (a separate layer stayed at the height of a row that was still arriving).
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
