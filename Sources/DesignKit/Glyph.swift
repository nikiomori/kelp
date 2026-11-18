import AppKit

/// Kelp's own line drawings for a few symbols, as the design has them: git's branch and pull request with their
/// commits as rings, a list with rings, CI's check in a ring, and the activity gauge. `NSImage.symbol` hands them out
/// under the SF Symbol names they replace, so every AppKit use (inspector, window bar, menus) gets them. They are
/// drawn on a 16-point grid with 1.3-point round strokes, as templates, so they tint as symbols do.
public enum Glyph {
    public static func image(_ name: String, size: CGFloat = 17) -> NSImage? {   // as tall as a 14-point symbol
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

/// SF Symbol image helper used by tabs and menus; a few names get Kelp's own drawing instead (Glyph).
/// It keeps one image per name and label, because an image equals only itself, so a fresh one on every call made each
/// tab, chip and row icon look changed on every session event (the tab strip's "nothing changed" check never held).
extension NSImage {
    public static func symbol(_ name: String, _ label: String? = nil) -> NSImage {
        let key = "\(name)\u{0}\(label ?? "")" as NSString
        if let known = symbolCache.object(forKey: key) { return known }
        let made =
            Glyph.image(name).map { glyph in
                glyph.accessibilityDescription = label
                return glyph
            }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        symbolCache.setObject(made, forKey: key)
        return made
    }
}
extension NSAttributedString {
    /// A count with its sign before it, as a branch's ↓3 and ↑37: the action's own symbol, then the number 2 pt after
    /// it in digits of one width, both in `color`. Whatever says how many commits wait to be pulled or pushed writes
    /// it with this (the title bar's chip, Source Control's header and its button), so the arrow is one drawing at
    /// every text size. Typed as "↑" it was the font's own arrow, another one at each size and in each theme's font.
    /// With no count it is the arrow alone, the same one: a button with nothing to move.
    @MainActor public static func signed(_ symbol: String, _ count: Int?, size: CGFloat, color: NSColor)
        -> NSAttributedString
    {
        let font = NSFont.uiDigits(size, weight: .semibold), text = NSMutableAttributedString()
        // The arrow is as heavy as the digits beside it, not the chrome's medium, which read as a hairline there.
        let arrow = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.iconTiny, weight: .semibold))
        if let arrow {
            let sign = NSTextAttachment()
            sign.image = arrow
            // On the digits' middle: an attachment stands on the baseline otherwise, half a line too high.
            sign.bounds = NSRect(origin: NSPoint(x: 0, y: (font.capHeight - arrow.size.height) / 2), size: arrow.size)
            text.append(NSAttributedString(attachment: sign))
            if count != nil { text.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: text.length)) }
        }
        if let count { text.append(NSAttributedString(string: "\(count)")) }
        text.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: text.length))
        return text
    }
}
// NSCache is thread-safe, and the images handed out aren't changed.
nonisolated(unsafe) private let symbolCache = NSCache<NSString, NSImage>()
