import AppKit
import DesignKit

/// What's drawn in the text that isn't text: rulers at set columns, and the whitespace you ask to see.
extension EditorTextView {
    public enum WhitespaceMarks: String, Sendable {
        case none, selection, trailing, all
    }

    private var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width }

    func drawRulers(in rect: NSRect) {
        guard !rulerColumns.isEmpty else { return }
        NSColor.separatorColor.setFill()
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), space = spaceWidth
        for c in rulerColumns { NSRect(x: x + CGFloat(c) * space, y: rect.minY, width: 1, height: rect.height).fill() }
    }

    /// Scanned in what's drawn only. Characters nobody means to have (no-break and zero-width spaces) are always marked.
    func drawWhitespace(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let s = string as NSString, origin = textContainerOrigin
        let shown = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil)
        guard shown.length > 0 else { return }
        var chars = [unichar](repeating: 0, count: shown.length)
        s.getCharacters(&chars, range: shown)
        let selected = selectedRanges.map(\.rangeValue), mode = whitespaceMarks
        let dot = spaceWidth * 0.2
        let tab = NSAttributedString(string: "→", attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        func place(_ i: Int) -> NSPoint {
            let g = lm.glyphIndexForCharacter(at: i), line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil), at = lm.location(forGlyphAt: g)
            return NSPoint(x: line.minX + at.x + origin.x, y: line.minY + origin.y + line.height / 2)
        }
        /// Spaces and tabs up to a line's end, from `k` on.
        func trailing(_ k: Int) -> Bool {
            var j = k
            while j < chars.count, chars[j] == 32 || chars[j] == 9 { j += 1 }
            return j == chars.count ? shown.location + j == s.length : chars[j] == 10 || chars[j] == 13
        }
        for (k, c) in chars.enumerated() {
            let i = shown.location + k
            if Self.isUnusualSpace(c) {
                NSColor.textOrange.setStroke()
                let p = place(i), box = NSBezierPath(rect: NSRect(x: p.x, y: p.y - 5, width: max(spaceWidth, 3), height: 10))
                box.stroke()
                continue
            }
            guard c == 32 || c == 9, mode != .none else { continue }
            let wanted = mode == .all || (mode == .trailing && trailing(k)) || (mode == .selection && selected.contains { NSLocationInRange(i, $0) })
            guard wanted else { continue }
            let p = place(i)
            if c == 9 {
                tab.draw(at: NSPoint(x: p.x, y: p.y - tab.size().height / 2))
            } else {
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x + spaceWidth / 2 - dot / 2, y: p.y - dot / 2, width: dot, height: dot)).fill()
            }
        }
    }

    static func isUnusualSpace(_ c: unichar) -> Bool {
        c == 0xA0 || (0x2000...0x200D).contains(c) || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF
    }
}
