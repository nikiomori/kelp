import AppKit

/// Kelp's own line drawings for a few symbols, as the design has them: git's branch and pull request with their
/// commits as rings, a list with rings, CI's check in a ring, the activity gauge. `NSImage.symbol` hands them out
/// under the SF Symbol names they replace, so every AppKit use (inspector, window bar, menus) gets them. Drawn on
/// a 16-point grid with 1.3-point round strokes, as templates: they tint like symbols do.
enum Glyph {
    static func image(_ name: String, size: CGFloat = 17) -> NSImage? {   // as tall as a 14-point symbol
        guard let shape = shapes[name] else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let path = NSBezierPath()
            shape(path)
            path.transform(using: AffineTransform(scale: rect.width / 16))
            path.lineWidth = 1.3 * rect.width / 16
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func ring(_ path: NSBezierPath, _ x: CGFloat, _ y: CGFloat, _ radius: CGFloat = 1.5) {
        path.appendOval(in: NSRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
    }
    private static func line(_ path: NSBezierPath, _ pts: (CGFloat, CGFloat)...) {
        guard let first = pts.first else { return }
        path.move(to: NSPoint(x: first.0, y: first.1))
        for point in pts.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
    }

    private static let shapes: [String: @Sendable (NSBezierPath) -> Void] = [
        // Source control: a branch leaving the trunk.
        "arrow.triangle.branch": { path in
            ring(path, 4, 3.5)
            ring(path, 4, 12.5)
            ring(path, 12, 5)
            line(path, (4, 5), (4, 11))
            path.move(to: NSPoint(x: 12, y: 6.5))
            path.curve(
                to: NSPoint(x: 4, y: 11), controlPoint1: NSPoint(x: 12, y: 9.5), controlPoint2: NSPoint(x: 4, y: 8.5))
        },
        // A pull request: the branch's commit coming back to the trunk.
        "arrow.triangle.pull": { path in
            ring(path, 4, 3.5)
            ring(path, 4, 12.5)
            ring(path, 12, 12.5)
            line(path, (4, 5), (4, 11))
            path.move(to: NSPoint(x: 12, y: 11))
            path.line(to: NSPoint(x: 12, y: 6.5))
            path.curve(
                to: NSPoint(x: 10, y: 4.5), controlPoint1: NSPoint(x: 12, y: 5.4),
                controlPoint2: NSPoint(x: 11.1, y: 4.5))
            path.line(to: NSPoint(x: 7.5, y: 4.5))
            line(path, (9, 3), (7.5, 4.5), (9, 6))
        },
        // Issues and pull requests: a list.
        "checklist": { path in
            ring(path, 3.5, 4.5)
            ring(path, 3.5, 11.5)
            line(path, (7, 4.5), (14, 4.5))
            line(path, (7, 11.5), (14, 11.5))
        },
        // CI: a check in a ring.
        "checkmark.seal": { path in
            ring(path, 8, 8, 6)
            line(path, (5.5, 8), (7.5, 10), (10.5, 6))
        },
        // Activity: a gauge.
        "gauge.with.dots.needle.33percent": { path in
            ring(path, 8, 8, 6)
            line(path, (8, 8), (11, 5))
            ring(path, 8, 8, 0.6)
        }
    ]
}
