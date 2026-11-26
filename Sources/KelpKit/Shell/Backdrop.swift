import AppKit
import QuartzCore

/// What a theme paints on the window's surface, under the panels and, in a theme whose card is clear, the terminals:
/// its colour and, in a drafting theme, a still grid.
@MainActor
final class Backdrop: NSView {
    private let grid = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // A theme change and the window's resize show at once, not as a fade or a slide.
        grid.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(grid)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ look: WindowLook) {
        layer?.backgroundColor = look.surface?.cgColor
        grid.backgroundColor = look.ambient.map { Self.grid($0.colors.first ?? .white) }
    }

    override func layout() {
        super.layout()
        grid.frame = bounds
    }

    /// A draughtsman's grid: fine lines, every fifth one stronger.
    private static func grid(_ color: NSColor) -> CGColor {
        let step: CGFloat = 20
        let tile = NSImage(size: NSSize(width: step * 5, height: step * 5), flipped: false) { bounds in
            for index in 0..<5 {
                color.withAlphaComponent(index == 0 ? 0.16 : 0.07).setFill()
                NSRect(x: CGFloat(index) * step, y: 0, width: 0.5, height: bounds.height).fill(using: .sourceOver)
                NSRect(x: 0, y: CGFloat(index) * step, width: bounds.width, height: 0.5).fill(using: .sourceOver)
            }
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }
}
