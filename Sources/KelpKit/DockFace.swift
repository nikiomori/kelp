import AppKit

/// What Kelp's Dock icon shows. Only what is drawn is in here, so the icon is redrawn when the drawing changes,
/// not at every status.
enum DockFace: Equatable {
    /// One agent's mark. In the order they are drawn: what wants you first.
    enum Cell: Int, Comparable {
        case asks, failed, done, working   // finished work is news; work going on is not
        static func < (a: Cell, b: Cell) -> Bool { a.rawValue < b.rawValue }
    }
    /// What fits in the pill.
    static let marks = 4

    case icon
    case agents([Cell])
    case usage(percent: Int, high: Bool)
}

/// The Dock draws this view's image at the size of the tile: 128 by 128 here, whatever the Dock's size. Kelp's icon stays
/// as it is and a pill lies across its foot, where macOS puts a Dock icon's progress bar. It is the icon's artwork, so its
/// sizes are the artwork's and don't follow Text Size; they are chosen to read at 52 pt, about the smallest Dock in use.
final class DockFaceView: NSView {
    var face = DockFace.icon { didSet { needsDisplay = true } }

    private static let pillHeight: CGFloat = 40, foot: CGFloat = 17, inset: CGFloat = 11
    private static let mark: CGFloat = 16, gap: CGFloat = 6

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128)) }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draw(_ dirty: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        switch face {
        case .icon: break
        case .agents(let cells): draw(cells)
        case .usage(let percent, let high):
            let text = label("\(percent)%", size: 30, color: high ? .systemOrange : .white)
            let inner = pill(width: text.size().width)
            text.draw(at: NSPoint(x: inner.minX, y: inner.midY - text.size().height / 2))
        }
    }

    /// As many marks as fit, what wants you first; the rest as a number, which takes the room of two.
    private func draw(_ cells: [DockFace.Cell]) {
        let marks = cells.prefix(cells.count > DockFace.marks ? DockFace.marks - 2 : DockFace.marks)
        let rest = cells.count - marks.count
        let more = rest > 0 ? label("+\(rest)", size: 26, color: .white) : nil
        let span = CGFloat(marks.count) * Self.mark + CGFloat(marks.count - 1) * Self.gap
        let inner = pill(width: span + (more.map { $0.size().width + Self.gap } ?? 0))
        var x = inner.minX
        for cell in marks {
            mark(cell, at: NSRect(x: x, y: inner.midY - Self.mark / 2, width: Self.mark, height: Self.mark))
            x += Self.mark + Self.gap
        }
        more?.draw(at: NSPoint(x: x, y: inner.midY - (more?.size().height ?? 0) / 2))
    }

    /// Lays the pill, and says where its content goes.
    private func pill(width: CGFloat) -> NSRect {
        let wide = width + 2 * Self.inset
        let shape = NSRect(x: bounds.midX - wide / 2, y: Self.foot, width: wide, height: Self.pillHeight)
        let path = NSBezierPath(roundedRect: shape, xRadius: Self.pillHeight / 2, yRadius: Self.pillHeight / 2)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.stroke()
        return shape.insetBy(dx: Self.inset, dy: 0)
    }

    private func mark(_ cell: DockFace.Cell, at box: NSRect) {
        let dot = NSBezierPath(ovalIn: box)
        switch cell {
        case .asks: NSColor.systemOrange.setFill(); dot.fill()
        case .failed: NSColor.systemRed.setFill(); dot.fill()
        case .working: NSColor.white.setFill(); dot.fill()
        case .done:   // a ring: done is told from working by form, as on every other mark
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 3
            NSColor.white.setStroke(); ring.stroke()
        }
    }

    private func label(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), .foregroundColor: color])
    }
}
