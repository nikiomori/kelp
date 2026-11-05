import AppKit

/// Kelp's own line drawings for a few symbols, as the design has them: git's branch and pull request with their
/// commits as rings, a list with rings, CI's check in a ring, the activity gauge. `NSImage.symbol` hands them out
/// under the SF Symbol names they replace, so every AppKit use (inspector, window bar, menus) gets them. Drawn on
/// a 16-point grid with 1.3-point round strokes, as templates: they tint like symbols do.
enum Glyph {
    static func image(_ name: String, size: CGFloat = 17) -> NSImage? {   // as tall as a 14-point symbol
        guard let shape = shapes[name] else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            let p = NSBezierPath(); shape(p)
            p.transform(using: AffineTransform(scale: r.width / 16))
            p.lineWidth = 1.3 * r.width / 16
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            NSColor.black.setStroke(); p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func ring(_ p: NSBezierPath, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 1.5) {
        p.appendOval(in: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    private static func line(_ p: NSBezierPath, _ pts: (CGFloat, CGFloat)...) {
        guard let first = pts.first else { return }
        p.move(to: NSPoint(x: first.0, y: first.1))
        for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
    }

    private static let shapes: [String: @Sendable (NSBezierPath) -> Void] = [
        // Source control: a branch leaving the trunk.
        "arrow.triangle.branch": { p in
            ring(p, 4, 3.5)
            ring(p, 4, 12.5)
            ring(p, 12, 5)
            line(p, (4, 5), (4, 11))
            p.move(to: NSPoint(x: 12, y: 6.5)); p.curve(to: NSPoint(x: 4, y: 11), controlPoint1: NSPoint(x: 12, y: 9.5), controlPoint2: NSPoint(x: 4, y: 8.5))
        },
        // A pull request: the branch's commit coming back to the trunk.
        "arrow.triangle.pull": { p in
            ring(p, 4, 3.5)
            ring(p, 4, 12.5)
            ring(p, 12, 12.5)
            line(p, (4, 5), (4, 11))
            p.move(to: NSPoint(x: 12, y: 11)); p.line(to: NSPoint(x: 12, y: 6.5))
            p.curve(to: NSPoint(x: 10, y: 4.5), controlPoint1: NSPoint(x: 12, y: 5.4), controlPoint2: NSPoint(x: 11.1, y: 4.5))
            p.line(to: NSPoint(x: 7.5, y: 4.5))
            line(p, (9, 3), (7.5, 4.5), (9, 6))
        },
        // Issues and pull requests: a list.
        "checklist": { p in
            ring(p, 3.5, 4.5); ring(p, 3.5, 11.5)
            line(p, (7, 4.5), (14, 4.5)); line(p, (7, 11.5), (14, 11.5))
        },
        // CI: a check in a ring.
        "checkmark.seal": { p in
            ring(p, 8, 8, 6)
            line(p, (5.5, 8), (7.5, 10), (10.5, 6))
        },
        // Activity: a gauge.
        "gauge.with.dots.needle.33percent": { p in
            ring(p, 8, 8, 6)
            line(p, (8, 8), (11, 5))
            ring(p, 8, 8, 0.6)
        }
    ]
}
