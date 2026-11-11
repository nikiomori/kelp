import AppKit

/// Folding by indentation, as VS Code does for most languages: a line whose next lines go in further can hide them
/// (from its own end to the end of the last one in), shown as a ⋯ capsule; the line that comes back out (a closing
/// `}`) stays. The hidden characters get null glyphs, so the text, its undo and the find bar don't change.
final class Folds: @unchecked Sendable {   // the main thread only: the layout manager asks for glyphs there
    /// Top to bottom, apart.
    private(set) var hidden: [NSRange] = []

    var isEmpty: Bool { hidden.isEmpty }

    /// The fold hiding `location`.
    func fold(at location: Int) -> NSRange? {
        var lo = 0, hi = hidden.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(hidden[mid]) <= location { lo = mid + 1 } else { hi = mid }
        }
        return lo < hidden.count && hidden[lo].location <= location ? hidden[lo] : nil
    }

    func intersects(_ range: NSRange) -> Bool { hidden.contains { NSIntersectionRange($0, range).length > 0 } }

    /// Folds `range`; one inside it goes (it's hidden anyway), one around it stays and this one isn't added.
    func add(_ range: NSRange) {
        guard fold(at: range.location) == nil else { return }
        hidden.removeAll { NSIntersectionRange($0, range).length > 0 }
        hidden.append(range)
        hidden.sort { $0.location < $1.location }
    }

    func remove(_ range: NSRange) { hidden.removeAll { $0 == range } }
    func removeAll() -> [NSRange] {
        defer { hidden = [] }
        return hidden
    }

    /// An edit about to be made (ranges top to bottom, new lengths): a fold it reaches into opens, those after it move.
    /// Returns the ones that opened, where they'll be.
    func edit(_ edits: [(NSRange, Int)]) -> [NSRange] {
        var kept: [NSRange] = [], opened: [NSRange] = []
        for folded in hidden {
            var shift = 0, hit = false
            for (range, newLength) in edits {
                if NSMaxRange(range) <= folded.location {
                    shift += newLength - range.length
                } else if range.location >= NSMaxRange(folded) {
                    break
                } else {
                    hit = true
                }
            }
            let moved = NSRange(location: folded.location + shift, length: folded.length)
            if hit { opened.append(moved) } else { kept.append(moved) }
        }
        hidden = kept
        return opened
    }

    // MARK: Regions

    /// What folding `line` hides: from its end to the end of the last following line that's further in; nil when the
    /// next non-blank line isn't.
    static func region(of line: NSRange, in string: NSString) -> NSRange? {
        guard let own = indent(line, in: string) else { return nil }
        var last: NSRange?, at = NSMaxRange(line)
        while at < string.length {
            let next = string.lineRange(for: NSRange(location: at, length: 0))
            if let level = indent(next, in: string) { if level > own { last = next } else { break } }
            at = NSMaxRange(next)
        }
        guard let last else { return nil }
        let start = MultiCursor.lineEnd(string, line.location), end = MultiCursor.lineEnd(string, last.location)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// A line's indent in columns (a tab is `tab`); nil for a blank line.
    static func indent(_ line: NSRange, in string: NSString, tab: Int = 4) -> Int? {
        var columns = 0
        for index in line.location..<NSMaxRange(line) {
            switch string.character(at: index) {
            case 32: columns += 1
            case 9: columns += tab - columns % tab
            case 10, 13: return nil
            default: return columns
            }
        }
        return nil
    }
}

extension EditorTextView: NSLayoutManagerDelegate {
    // swiftlint:disable function_parameter_count
    /// Folded characters get null glyphs: no width, no line of their own.
    public nonisolated func layoutManager(
        _ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
        font: NSFont, forGlyphRange range: NSRange
    ) -> Int {
        guard range.length > 0, !folds.isEmpty else { return 0 }
        let chars = NSRange(
            location: characterIndexes[0], length: characterIndexes[range.length - 1] - characterIndexes[0] + 1)
        guard folds.intersects(chars) else { return 0 }
        var props = Array(UnsafeBufferPointer(start: properties, count: range.length))
        for index in 0..<range.length where folds.fold(at: characterIndexes[index]) != nil { props[index] = .null }
        lm.setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }
    // swiftlint:enable function_parameter_count

    /// Folds `range` (or opens it), laid out again.
    func setFolded(_ range: NSRange, _ on: Bool) {
        if on { folds.add(range) } else { folds.remove(range) }
        relayOut(range)
        if on, let caret = cursors.first?.location, NSLocationInRange(caret, range), caret != range.location {
            setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    func relayOut(_ range: NSRange) {
        guard let lm = layoutManager, NSMaxRange(range) <= length else { return }
        lm.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Where a fold's ⋯ capsule is drawn: after its line's text.
    func capsule(for fold: NSRange) -> NSRect {
        let caret = caretRect(at: fold.location)
        let width = ((font ?? .systemFont(ofSize: 13)).maximumAdvancement.width) * 2.4
        return NSRect(x: caret.minX + 4, y: caret.minY + 2, width: max(width, 18), height: max(caret.height - 4, 8))
    }

    func drawCapsules(in dirty: NSRect) {
        guard !folds.isEmpty else { return }
        let color = textColor ?? .labelColor
        for fold in folds.hidden {
            let box = capsule(for: fold)
            guard box.intersects(dirty) else { continue }
            color.withAlphaComponent(fold == hoveredFold ? 0.24 : 0.14).setFill()   // under the pointer it brightens
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            let dots = NSAttributedString(
                string: "⋯",
                attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: color.withAlphaComponent(0.7)])
            let size = dots.size()
            dots.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
        }
    }
}

extension CodeEditor {
    /// ⌥⌘[: the block the cursor's line opens, or else the innermost one around the cursor.
    public func fold() {
        let string = textView.string as NSString, caret = textView.selectedRange().location
        var line = string.lineRange(for: NSRange(location: caret, length: 0))
        if let region = foldRegion(line, in: string) { return textView.setFolded(region, true) }
        // Up to the lines that are less indented: the blocks around the cursor, innermost first.
        var limit = Folds.indent(line, in: string) ?? Int.max
        while line.location > 0, limit > 0 {
            line = string.lineRange(for: NSRange(location: line.location - 1, length: 0))
            guard let level = Folds.indent(line, in: string), level < limit else { continue }
            if let region = foldRegion(line, in: string), caret <= NSMaxRange(region) {
                return textView.setFolded(region, true)
            }
            limit = level
        }
        NSSound.beep()
    }

    /// ⌥⌘]: the fold on the cursor's line, or around it.
    public func unfold() {
        let string = textView.string as NSString, caret = textView.selectedRange().location
        let line = string.lineRange(for: NSRange(location: caret, length: 0))
        guard
            let folded = textView.folds.fold(at: MultiCursor.lineEnd(string, line.location))
                ?? textView.folds.fold(at: caret)
        else { return NSSound.beep() }
        textView.setFolded(folded, false)
    }

    public func unfoldAll() { textView.folds.removeAll().forEach { textView.relayOut($0) } }

    /// A click on the gutter's chevron: the line's block folds, or opens.
    func toggleFold(line: NSRange) {
        let string = textView.string as NSString
        if let folded = textView.folds.fold(at: MultiCursor.lineEnd(string, line.location)) {
            return textView.setFolded(folded, false)
        }
        if let region = foldRegion(line, in: string) { textView.setFolded(region, true) }
    }
}
