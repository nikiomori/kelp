import AppKit
import DesignKit

/// The elements' lanes as layers: the frontmost on top. A lane dragged by its name to another place restacks the
/// elements (`onRestack`), its eye hides the element from the page and the video (`onHide`), and the lanes scroll when
/// there are more than fit.
extension MotionTimeline {
    /// Where lane `lane`'s eye is, at the end of its name.
    func eyeRect(lane: Int) -> NSRect {
        let row = laneRect(lane)
        return NSRect(x: Self.names - Metrics.gap - 16, y: row.midY - 8, width: 16, height: 16)
    }

    func drawEye(lane: Int, hidden: Bool) {
        let image = NSImage.symbol(hidden ? "eye.slash" : "eye")
        let color = NSImage.SymbolConfiguration(hierarchicalColor: hidden ? .tertiaryLabelColor : .secondaryLabelColor)
        let tinted = image.withSymbolConfiguration(color) ?? image
        let r = eyeRect(lane: lane), k = min(r.width / max(image.size.width, 1), 1)
        let size = NSSize(width: image.size.width * k, height: image.size.height * k)
        tinted.draw(
            in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// While a lane is dragged, a line where it would go.
    func drawLaneDrag() {
        guard let laneDrag, laneDrag.to != laneDrag.from else { return }
        let y = laneRect(laneDrag.to + (laneDrag.to > laneDrag.from ? 1 : 0)).minY
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: y - 1, width: bounds.width, height: 2).fill()
    }

    /// The element lane (1 and on) under `p`, in the names' column.
    private func layer(at p: NSPoint) -> Int? {
        guard p.x < track.minX, lanesArea.contains(p) else { return nil }
        let lane = Int(((p.y - lanesArea.minY + laneOffset) / Self.lane).rounded(.down))
        return (1...max(tracks.count, 1)).contains(lane) && lane <= tracks.count ? lane : nil
    }

    /// A press in the names' column: the eye hides or shows the element, the name starts dragging its lane.
    func layerDown(at p: NSPoint) -> Bool {
        guard let lane = layer(at: p) else { return false }
        let clip = tracks[lane - 1]
        guard !clip.id.isEmpty else { return true }
        if eyeRect(lane: lane).insetBy(dx: -3, dy: -3).contains(p) {
            onHide?(clip.id, !clip.hidden)
        } else {
            laneDrag = (lane - 1, lane - 1)
        }
        return true
    }

    func layerDragged(to p: NSPoint) -> Bool {
        guard var drag = laneDrag else { return false }
        let lane = Int(((p.y - lanesArea.minY + laneOffset) / Self.lane).rounded(.down)) - 1
        drag.to = min(max(lane, 0), tracks.count - 1)
        laneDrag = drag
        needsDisplay = true
        return true
    }

    /// The lane let go: the elements in their new order, when it moved.
    func layerUp() -> Bool {
        guard let drag = laneDrag else { return false }
        laneDrag = nil
        needsDisplay = true
        guard drag.to != drag.from else { return true }
        var order = tracks.map(\.id)
        order.insert(order.remove(at: drag.from), at: drag.to)
        onRestack?(order.filter { !$0.isEmpty })
        return true
    }

    /// Scrolls the lanes up or down when there are more than fit. Returns whether it did.
    func scrollLanes(by delta: CGFloat) -> Bool {
        let room = lanesArea.height, needed = Self.lane * CGFloat(1 + tracks.count)
        guard needed > room, delta != 0 else { return false }
        laneOffset = min(max(laneOffset - delta, 0), needed - room)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        return true
    }
}
