import AppKit

/// Thin diagonal lines over a resting fill: what stands apart from the rest it's drawn with, a bar's free part (as
/// `PartsBar` draws it) or the places outside a project in an agent's work map.
public enum Hatching {
    /// Between two lines.
    public static let step: CGFloat = 4
    /// The lines' colour.
    public static let color = NSColor.tertiaryLabelColor

    /// Fills `path` with the resting fill and the lines, in the current graphics context.
    @MainActor public static func fill(_ path: NSBezierPath) {
        NSColor.fillRest.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        path.addClip()
        let box = path.bounds, lines = NSBezierPath()
        var x = box.minX - box.height
        while x < box.maxX {
            lines.move(to: NSPoint(x: x, y: box.maxY))
            lines.line(to: NSPoint(x: x + box.height, y: box.minY))
            x += step
        }
        lines.lineWidth = 1
        color.setStroke()
        lines.stroke()
    }
}
