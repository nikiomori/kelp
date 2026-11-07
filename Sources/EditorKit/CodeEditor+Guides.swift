import AppKit
import DesignKit

/// What's drawn in the text that isn't text: rulers at set columns, and the whitespace you ask to see.
extension EditorTextView {
    public enum WhitespaceMarks: String, Sendable {
        case none, selection, trailing, all
    }

    private var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
    }

    func drawRulers(in rect: NSRect) {
        guard !rulerColumns.isEmpty else { return }
        NSColor.separatorColor.setFill()
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), space = spaceWidth
        for c in rulerColumns { NSRect(x: x + CGFloat(c) * space, y: rect.minY, width: 1, height: rect.height).fill() }
    }

    /// A faint line per indent level, the block around the cursor's brighter. For what's drawn only: a line's own leading
    /// spaces, so it costs the same in any file.
    func drawIndentGuides(in rect: NSRect) {
        guard indentGuides, let lm = layoutManager, let tc = textContainer else { return }
        let s = string as NSString, origin = textContainerOrigin, step = CGFloat(guideColumns) * spaceWidth,
            left = origin.x + tc.lineFragmentPadding
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let active = activeGuide(in: s)
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, g, _ in
            let at = lm.characterIndexForGlyph(at: g.location),
                line = s.lineRange(for: NSRange(location: at, length: 0))
            for k in 0..<self.guideLevels(line, in: s) {
                let bright = active.map { k == $0.level - 1 && NSLocationInRange(at, $0.block) } ?? false
                (bright ? NSColor.tertiaryLabelColor : NSColor.separatorColor).setFill()
                NSRect(x: left + CGFloat(k) * step, y: frag.minY + origin.y, width: 1, height: frag.height).fill()
            }
        }
    }

    /// Whole indents at a line's start; nil for a blank line.
    func indentLevel(_ line: NSRange, in s: NSString) -> Int? {
        var columns = 0
        for k in line.location..<NSMaxRange(line) {
            switch s.character(at: k) {
            case 32: columns += 1
            case 9: columns += guideColumns - columns % guideColumns
            case 10, 13: return nil
            default: return columns / max(guideColumns, 1)
            }
        }
        return nil
    }

    /// A blank line goes on as far as the less indented of the lines either side.
    private func guideLevels(_ line: NSRange, in s: NSString) -> Int {
        if let n = indentLevel(line, in: s) { return n }
        func next(_ down: Bool) -> Int {
            var at = down ? NSMaxRange(line) : line.location - 1, tries = 0
            while at >= 0, at < s.length, tries < 50 {
                let l = s.lineRange(for: NSRange(location: at, length: 0))
                if let n = indentLevel(l, in: s) { return n }
                at = down ? NSMaxRange(l) : l.location - 1
                tries += 1
            }
            return 0
        }
        return min(next(false), next(true))
    }

    /// The cursor's line and those around it indented as far: within what's on screen, the only part that shows.
    private func activeGuide(in s: NSString) -> (level: Int, block: NSRange)? {
        guard let lm = layoutManager, let tc = textContainer, selectedRange().location <= s.length else { return nil }
        let here = s.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let level = guideLevels(here, in: s)
        guard level > 0 else { return nil }
        let shown = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: visibleRect, in: tc), actualGlyphRange: nil)
        var from = here, to = here
        while from.location > shown.location {
            let l = s.lineRange(for: NSRange(location: from.location - 1, length: 0))
            guard guideLevels(l, in: s) >= level else { break }
            from = l
        }
        while NSMaxRange(to) < NSMaxRange(shown) {
            let l = s.lineRange(for: NSRange(location: NSMaxRange(to), length: 0))
            guard guideLevels(l, in: s) >= level else { break }
            to = l
        }
        return (level, NSRange(location: from.location, length: NSMaxRange(to) - from.location))
    }

    /// Scanned in what's drawn only. Characters nobody means to have (no-break and zero-width spaces) are always marked.
    func drawWhitespace(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let s = string as NSString, origin = textContainerOrigin
        let shown = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil)
        guard shown.length > 0 else { return }
        var chars = [unichar](repeating: 0, count: shown.length)
        s.getCharacters(&chars, range: shown)
        let selected = selectedRanges.map(\.rangeValue), mode = whitespaceMarks
        let dot = spaceWidth * 0.2
        let tab = NSAttributedString(
            string: "→",
            attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        func place(_ i: Int) -> NSPoint {
            let g = lm.glyphIndexForCharacter(at: i), line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil),
                at = lm.location(forGlyphAt: g)
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
            if folds.fold(at: i) != nil { continue }   // in no line: its mark would land on the fold's
            if Self.isUnusualSpace(c) {
                NSColor.textOrange.setStroke()
                let p = place(i),
                    box = NSBezierPath(rect: NSRect(x: p.x, y: p.y - 5, width: max(spaceWidth, 3), height: 10))
                box.stroke()
                continue
            }
            guard c == 32 || c == 9, mode != .none else { continue }
            let wanted =
                mode == .all || (mode == .trailing && trailing(k))
                || (mode == .selection && selected.contains { NSLocationInRange(i, $0) })
            guard wanted else { continue }
            let p = place(i)
            if c == 9 {
                tab.draw(at: NSPoint(x: p.x, y: p.y - tab.size().height / 2))
            } else {
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(
                    ovalIn: NSRect(x: p.x + spaceWidth / 2 - dot / 2, y: p.y - dot / 2, width: dot, height: dot)
                ).fill()
            }
        }
    }

    static func isUnusualSpace(_ c: unichar) -> Bool {
        c == 0xA0 || (0x2000...0x200D).contains(c) || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF
    }
}
