import AppKit

/// What Kelp's Dock icon shows. Only what is drawn is in here, so the icon is redrawn when the drawing changes,
/// not at every status.
enum DockFace: Equatable {
    /// One agent's square. In the order they are drawn: what wants you first.
    enum Cell: Int, Comparable {
        case asks, failed, working, done
        static func < (a: Cell, b: Cell) -> Bool { a.rawValue < b.rawValue }
    }
    static let cells = 9

    case icon
    case agents([Cell])
    case usage(percent: Int, high: Bool)
}

/// The Dock draws this view's image at the size of the tile: 128 by 128 here, whatever the Dock's size. It is the icon's
/// artwork, so its sizes are the artwork's and don't follow Text Size; 52 pt is about the smallest a Dock is used at.
final class DockFaceView: NSView {
    var face = DockFace.icon { didSet { needsDisplay = true } }

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128)) }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func draw(_ dirty: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard face != .icon else { return }
        // The artwork shows through: it still reads as Kelp among the Dock's other icons.
        let ground = bounds.insetBy(dx: 13, dy: 13)
        NSColor(red: 0.02, green: 0.09, blue: 0.12, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: ground, xRadius: 22, yRadius: 22).fill()
        switch face {
        case .icon: break
        case .agents(let cells): draw(cells, in: ground.insetBy(dx: 12, dy: 12))
        case .usage(let percent, let high): draw(percent, high: high, in: ground.insetBy(dx: 12, dy: 12))
        }
    }

    private func draw(_ cells: [DockFace.Cell], in box: NSRect) {
        let gap: CGFloat = 5, side = (box.width - 2 * gap) / 3
        for i in 0..<DockFace.cells {
            let column = CGFloat(i % 3), row = CGFloat(i / 3)
            let square = NSRect(x: box.minX + column * (side + gap), y: box.maxY - (row + 1) * side - row * gap, width: side, height: side)
            let shape = NSBezierPath(roundedRect: square, xRadius: 5, yRadius: 5)
            switch i < cells.count ? cells[i] : nil {
            case .asks: NSColor.systemOrange.setFill(); shape.fill()
            case .failed: NSColor.systemRed.setFill(); shape.fill()
            case .working: NSColor.white.withAlphaComponent(0.85).setFill(); shape.fill()
            case .done:   // the same shape as a ring: done is told from working by form, as on every other mark
                let ring = NSBezierPath(roundedRect: square.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
                ring.lineWidth = 3
                NSColor.white.withAlphaComponent(0.7).setStroke(); ring.stroke()
            case nil: NSColor.white.withAlphaComponent(0.1).setFill(); shape.fill()
            }
        }
    }

    private func draw(_ percent: Int, high: Bool, in box: NSRect) {
        let color: NSColor = high ? .systemOrange : .white
        let text = NSAttributedString(string: "\(percent)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: percent >= 100 ? 40 : 46, weight: .semibold), .foregroundColor: color
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2 + 7))
        let track = NSRect(x: box.minX, y: box.minY + 4, width: box.width, height: 8)
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        var filled = track
        filled.size.width = max(track.height, track.width * CGFloat(min(percent, 100)) / 100)
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 4, yRadius: 4).fill()
    }
}
