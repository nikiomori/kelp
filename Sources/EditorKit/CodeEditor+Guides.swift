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
        let textLeft = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), space = spaceWidth
        for column in rulerColumns {
            NSRect(x: textLeft + CGFloat(column) * space, y: rect.minY, width: 1, height: rect.height).fill()
        }
    }

    /// A faint line per indent level, the block around the cursor's brighter. For what's drawn only: a line's own leading
    /// spaces, so it costs the same in any file.
    func drawIndentGuides(in rect: NSRect) {
        guard indentGuides, let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString, origin = textContainerOrigin, step = CGFloat(guideColumns) * spaceWidth,
            left = origin.x + tc.lineFragmentPadding
        let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let active = activeGuide(in: text)
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, lineGlyphs, _ in
            let at = lm.characterIndexForGlyph(at: lineGlyphs.location),
                line = text.lineRange(for: NSRange(location: at, length: 0))
            for level in 0..<self.guideLevels(line, in: text) {
                let bright = active.map { level == $0.level - 1 && NSLocationInRange(at, $0.block) } ?? false
                (bright ? NSColor.tertiaryLabelColor : NSColor.separatorColor).setFill()
                NSRect(x: left + CGFloat(level) * step, y: frag.minY + origin.y, width: 1, height: frag.height).fill()
            }
        }
    }

    /// Whole indents at a line's start; nil for a blank line.
    func indentLevel(_ line: NSRange, in text: NSString) -> Int? {
        var columns = 0
        for index in line.location..<NSMaxRange(line) {
            switch text.character(at: index) {
            case 32: columns += 1
            case 9: columns += guideColumns - columns % guideColumns
            case 10, 13: return nil
            default: return columns / max(guideColumns, 1)
            }
        }
        return nil
    }

    /// A blank line goes on as far as the less indented of the lines either side.
    private func guideLevels(_ line: NSRange, in text: NSString) -> Int {
        if let level = indentLevel(line, in: text) { return level }
        func next(_ down: Bool) -> Int {
            var at = down ? NSMaxRange(line) : line.location - 1, tries = 0
            while at >= 0, at < text.length, tries < 50 {
                let neighbour = text.lineRange(for: NSRange(location: at, length: 0))
                if let level = indentLevel(neighbour, in: text) { return level }
                at = down ? NSMaxRange(neighbour) : neighbour.location - 1
                tries += 1
            }
            return 0
        }
        return min(next(false), next(true))
    }

    /// The cursor's line and those around it indented as far: within what's on screen, the only part that shows.
    private func activeGuide(in text: NSString) -> (level: Int, block: NSRange)? {
        guard let lm = layoutManager, let tc = textContainer, selectedRange().location <= text.length else {
            return nil
        }
        let here = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let level = guideLevels(here, in: text)
        guard level > 0 else { return nil }
        let shown = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: visibleRect, in: tc), actualGlyphRange: nil)
        var from = here, to = here
        while from.location > shown.location {
            let line = text.lineRange(for: NSRange(location: from.location - 1, length: 0))
            guard guideLevels(line, in: text) >= level else { break }
            from = line
        }
        while NSMaxRange(to) < NSMaxRange(shown) {
            let line = text.lineRange(for: NSRange(location: NSMaxRange(to), length: 0))
            guard guideLevels(line, in: text) >= level else { break }
            to = line
        }
        return (level, NSRange(location: from.location, length: NSMaxRange(to) - from.location))
    }

    /// Scanned in what's drawn only. Characters nobody means to have (no-break and zero-width spaces) are always marked.
    func drawWhitespace(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString, origin = textContainerOrigin
        let shown = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil)
        guard shown.length > 0 else { return }
        var chars = [unichar](repeating: 0, count: shown.length)
        text.getCharacters(&chars, range: shown)
        let selected = selectedRanges.map(\.rangeValue), mode = whitespaceMarks
        let dot = spaceWidth * 0.2
        let tab = NSAttributedString(
            string: "→",
            attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
        func place(_ offset: Int) -> NSPoint {
            let glyph = lm.glyphIndexForCharacter(at: offset),
                line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil),
                at = lm.location(forGlyphAt: glyph)
            return NSPoint(x: line.minX + at.x + origin.x, y: line.minY + origin.y + line.height / 2)
        }
        /// Spaces and tabs up to a line's end, from `start` on.
        func trailing(_ start: Int) -> Bool {
            var end = start
            while end < chars.count, chars[end] == 32 || chars[end] == 9 { end += 1 }
            return end == chars.count ? shown.location + end == text.length : chars[end] == 10 || chars[end] == 13
        }
        for (index, character) in chars.enumerated() {
            let location = shown.location + index
            if folds.fold(at: location) != nil { continue }   // in no line: its mark would land on the fold's
            if Self.isUnusualSpace(character) {
                NSColor.textOrange.setStroke()
                let point = place(location),
                    box = NSBezierPath(rect: NSRect(x: point.x, y: point.y - 5, width: max(spaceWidth, 3), height: 10))
                box.stroke()
                continue
            }
            guard character == 32 || character == 9, mode != .none else { continue }
            let wanted =
                mode == .all || (mode == .trailing && trailing(index))
                || (mode == .selection && selected.contains { NSLocationInRange(location, $0) })
            guard wanted else { continue }
            let point = place(location)
            if character == 9 {
                tab.draw(at: NSPoint(x: point.x, y: point.y - tab.size().height / 2))
            } else {
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(
                    ovalIn: NSRect(x: point.x + spaceWidth / 2 - dot / 2, y: point.y - dot / 2, width: dot, height: dot)
                ).fill()
            }
        }
    }

    static func isUnusualSpace(_ character: unichar) -> Bool {
        character == 0xA0 || (0x2000...0x200D).contains(character) || character == 0x202F || character == 0x205F
            || character == 0x3000 || character == 0xFEFF
    }
}
