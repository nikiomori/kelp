import AppKit
import DesignKit

/// The selection pill on its way from the row it stood on to the row picked, on the spring a switch settles on
/// (`Motion.switchSpring`), instead of jumping there. It lies under the rows, so their names stay over it, and the
/// picked row draws its own pill once it's there (`SidebarRowView.pillWaits`).
@MainActor
final class PillGlide: NSView {
    private weak var end: SidebarRowView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Glides the pill from `start`'s to `end`'s, over `outline`. A glide still under way is cut short, and the new one
    /// leaves from where it had got to.
    static func run(from start: SidebarRowView, to end: SidebarRowView, in outline: NSOutlineView) {
        let going = outline.subviews.compactMap { $0 as? PillGlide }
        let from = going.last?.layer?.presentation()?.frame ?? start.convert(start.pillRect, to: outline)
        going.forEach { $0.finish() }
        let glide = PillGlide(frame: end.convert(end.pillRect, to: outline))
        glide.end = end
        glide.wantsLayer = true
        guard let layer = glide.layer else { return }
        layer.cornerRadius = SidebarRowView.pillRadius(inCard: end.group != nil)
        layer.backgroundColor = end.pillFill.cgColor
        if let shadow = end.pillShadow {
            layer.shadowColor = shadow.shadowColor?.cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius = shadow.shadowBlurRadius / 2
            layer.shadowOffset = CGSize(width: 0, height: -shadow.shadowOffset.height)   // the outline is flipped
        }
        outline.addSubview(glide, positioned: .below, relativeTo: outline.subviews.first { $0 is NSTableRowView })
        end.pillWaits = true
        for row in [start, end] { row.layer?.removeAnimation(forKey: "crossfade") }   // the pill travels, not fades
        let anchor = layer.anchorPoint, to = glide.frame
        func point(_ rect: NSRect) -> CGPoint {
            CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)
        }
        let move = Motion.switchSpring("position")
        move.fromValue = NSValue(point: layer.position + (point(from) - point(to)))
        move.toValue = NSValue(point: layer.position)
        let size = Motion.switchSpring("bounds.size")
        size.fromValue = NSValue(size: from.size)
        size.toValue = NSValue(size: to.size)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak glide] in
            MainActor.assumeIsolated { glide?.finish() }   // Core Animation runs the completion on the main thread
        }
        layer.add(move, forKey: "glide")
        layer.add(size, forKey: "glideSize")
        CATransaction.commit()
    }

    private func finish() {
        end?.pillWaits = false
        removeFromSuperview()
    }
}

extension CGPoint {
    fileprivate static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    fileprivate static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}

extension SidebarController {
    /// Called when the outline's selection changed: the pill glides from the row it stood on to the one picked, when
    /// both are on screen and motion is on. Otherwise it fades over, as before.
    func glidePill() {
        let picked = outline.selectedRowIndexes.count == 1 ? outline.selectedRow : -1
        let key = picked >= 0 ? (outline.item(atRow: picked) as? Node)?.key : nil
        defer { pillAt = key }
        guard let key, let was = pillAt, was != key, !Motion.reduced, outline.window?.isVisible == true,
            let old = node(was).map({ outline.row(forItem: $0) }), old >= 0,
            let start = outline.rowView(atRow: old, makeIfNecessary: false) as? SidebarRowView,
            let end = outline.rowView(atRow: picked, makeIfNecessary: false) as? SidebarRowView
        else { return }
        PillGlide.run(from: start, to: end, in: outline)
    }
}
