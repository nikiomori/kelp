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
    private func padded(_ r: NSRect, _ row: Int) -> NSRect {
        let p = pads(row)
        return NSRect(x: r.minX, y: r.minY + p.top, width: r.width, height: r.height - p.top - p.bottom)
    }
}

/// Like Safari's tab groups: a project with rows under it sits on a quiet card, and the row you're on is a raised pill
/// (no accent colour, so the text and the status marks keep theirs). A project with nothing under it is a plain row.
@MainActor
final class SidebarRowView: NSTableRowView {
    /// Where this row is in its project's card; the outline leaves room for its ends (`pads`).
    var group: (first: Bool, last: Bool)? { didSet { if group?.first != oldValue?.first || group?.last != oldValue?.last { needsDisplay = true } } }
    private var keyWatch: [NSObjectProtocol] = []

    /// A project's card: 4 pt over its first row and under its last (8 between cards), 4 more inside under the rows below its name.
    static func pads(_ g: (first: Bool, last: Bool)) -> (top: CGFloat, bottom: CGFloat) { (g.first ? 4 : 0, g.last ? (g.first ? 4 : 8) : 0) }

    static let groupFill = NSColor.fillRest

    override func drawBackground(in r: NSRect) {
        // Rows in the middle extend past their bounds, so only a card's ends are rounded. Flipped: y grows down.
        let pad = group.map(Self.pads) ?? (top: 0, bottom: 0)
        if let group {
            fill(band(6), first: group.first, top: 4, last: group.last, bottom: 4, radius: 9, Self.groupFill)
        }
        guard isSelected else { return }   // the outline draws no selection of its own (selectionHighlightStyle .none)
        // In a card the pill is 4 pt inside it, its corners following the card's (9 − 4); a row on its own gets a pill
        // where its card would be.
        var pill = group == nil ? band(6).insetBy(dx: 0, dy: 1) : band(10).insetBy(dx: 0, dy: 2)
        pill.origin.y += pad.top; pill.size.height -= pad.top + pad.bottom
        let path = NSBezierPath(roundedRect: pill, xRadius: group == nil ? 9 : 5, yRadius: group == nil ? 9 : 5)
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
    private func band(_ inset: CGFloat) -> NSRect {
        NSRect(x: bounds.minX + inset + 2, y: bounds.minY, width: bounds.width - 2 * inset + 4, height: bounds.height)
    }
    // swiftlint:disable:next function_parameter_count
    private func fill(_ r: NSRect, first: Bool, top: CGFloat, last: Bool, bottom: CGFloat, radius: CGFloat, _ color: NSColor) {
        var r = r
        let grow = first ? -top : 12
        r.origin.y -= grow
        r.size.height += grow
        r.size.height += last ? -bottom : 12
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
    /// The outline sizes a row's cell once; when the row's height changes later (a project's last row gains or loses the
    /// card's foot) the cell would only stretch with it, its text off the chevron. Put it where the outline says.
    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        guard let o = superview as? NSOutlineView, case let row = o.row(for: self), row >= 0,
              let cell = subviews.first(where: { $0 is NSTableCellView }) else { return }
        let f = o.frameOfCell(atColumn: 0, row: row)   // only its height: mid-update a project's row comes back narrower
        cell.frame = NSRect(x: cell.frame.minX, y: f.minY - o.rect(ofRow: row).minY, width: cell.frame.width, height: f.height)
    }
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            for case let c as SidebarCell in subviews { c.selected = isSelected }   // its grey text a step lighter on the pill
        }
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
