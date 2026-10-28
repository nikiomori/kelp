import AppKit

/// Folding by indentation, as VS Code does for most languages: a line whose next lines go in further can hide them
/// (from its own end to the end of the last one in), shown as a ⋯ capsule; the line that comes back out (a closing
/// `}`) stays. The hidden characters get null glyphs, so the text, its undo and the find bar don't change.
final class Folds: @unchecked Sendable {   // the main thread only: the layout manager asks for glyphs there
    /// Top to bottom, apart.
    private(set) var hidden: [NSRange] = []

    var isEmpty: Bool { hidden.isEmpty }

    /// The fold hiding `i`.
    func fold(at i: Int) -> NSRange? {
        var lo = 0, hi = hidden.count
        while lo < hi { let mid = (lo + hi) / 2; if NSMaxRange(hidden[mid]) <= i { lo = mid + 1 } else { hi = mid } }
        return lo < hidden.count && hidden[lo].location <= i ? hidden[lo] : nil
    }

    func intersects(_ r: NSRange) -> Bool { hidden.contains { NSIntersectionRange($0, r).length > 0 } }

    /// Folds `r`; one inside it goes (it's hidden anyway), one around it stays and this one isn't added.
    func add(_ r: NSRange) {
        guard fold(at: r.location) == nil else { return }
        hidden.removeAll { NSIntersectionRange($0, r).length > 0 }
        hidden.append(r)
        hidden.sort { $0.location < $1.location }
    }

    func remove(_ r: NSRange) { hidden.removeAll { $0 == r } }
    func removeAll() -> [NSRange] { defer { hidden = [] }; return hidden }

    /// An edit about to be made (ranges top to bottom, new lengths): a fold it reaches into opens, those after it move.
    /// Returns the ones that opened, where they'll be.
    func edit(_ edits: [(NSRange, Int)]) -> [NSRange] {
        var kept: [NSRange] = [], opened: [NSRange] = []
        for f in hidden {
            var shift = 0, hit = false
            for (r, n) in edits {
                if NSMaxRange(r) <= f.location {
                    shift += n - r.length
                } else if r.location >= NSMaxRange(f) {
                    break
                } else {
                    hit = true
                }
            }
            let moved = NSRange(location: f.location + shift, length: f.length)
            if hit { opened.append(moved) } else { kept.append(moved) }
        }
        hidden = kept
        return opened
    }

    // MARK: Regions

    /// What folding `line` hides: from its end to the end of the last following line that's further in; nil when the
    /// next non-blank line isn't.
    static func region(of line: NSRange, in s: NSString) -> NSRange? {
        guard let own = indent(line, in: s) else { return nil }
        var last: NSRange?, i = NSMaxRange(line)
        while i < s.length {
            let l = s.lineRange(for: NSRange(location: i, length: 0))
            if let n = indent(l, in: s) { if n > own { last = l } else { break } }
            i = NSMaxRange(l)
        }
        guard let last else { return nil }
        let start = MultiCursor.lineEnd(s, line.location), end = MultiCursor.lineEnd(s, last.location)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Whether `line` could fold: the next non-blank line is further in (cheap: the gutter asks for every line shown).
    static func canFold(_ line: NSRange, in s: NSString) -> Bool {
        guard let own = indent(line, in: s) else { return false }
        var i = NSMaxRange(line)
        while i < s.length {
            let l = s.lineRange(for: NSRange(location: i, length: 0))
            if let n = indent(l, in: s) { return n > own }
            i = NSMaxRange(l)
        }
        return false
    }

    /// A line's indent in columns (a tab is 4); nil for a blank line.
    static func indent(_ line: NSRange, in s: NSString) -> Int? {
        var n = 0
        for k in line.location..<NSMaxRange(line) {
            switch s.character(at: k) {
            case 32: n += 1
            case 9: n += 4 - n % 4
            case 10, 13: return nil
            default: return n
            }
        }
        return nil
    }
}

extension EditorTextView: NSLayoutManagerDelegate {
    // swiftlint:disable function_parameter_count
    /// Folded characters get null glyphs: no width, no line of their own.
    public nonisolated func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                          properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                                          font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard range.length > 0, !folds.isEmpty else { return 0 }
        let chars = NSRange(location: characterIndexes[0], length: characterIndexes[range.length - 1] - characterIndexes[0] + 1)
        guard folds.intersects(chars) else { return 0 }
        var props = Array(UnsafeBufferPointer(start: properties, count: range.length))
        for k in 0..<range.length where folds.fold(at: characterIndexes[k]) != nil { props[k] = .null }
        lm.setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }
    // swiftlint:enable function_parameter_count

    /// Folds `r` (or opens it), laid out again.
    func setFolded(_ r: NSRange, _ on: Bool) {
        if on { folds.add(r) } else { folds.remove(r) }
        relayOut(r)
        if on, let i = cursors.first?.location, NSLocationInRange(i, r), i != r.location { setSelectedRange(NSRange(location: r.location, length: 0)) }
    }

    func relayOut(_ r: NSRange) {
        guard let lm = layoutManager, NSMaxRange(r) <= length else { return }
        lm.invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Where a fold's ⋯ capsule is drawn: after its line's text.
    func capsule(for r: NSRange) -> NSRect {
        let caret = caretRect(at: r.location)
        let w = ((font ?? .systemFont(ofSize: 13)).maximumAdvancement.width) * 2.4
        return NSRect(x: caret.minX + 4, y: caret.minY + 2, width: max(w, 18), height: max(caret.height - 4, 8))
    }

    func drawCapsules(in dirty: NSRect) {
        guard !folds.isEmpty else { return }
        let color = textColor ?? .labelColor
        for r in folds.hidden {
            let box = capsule(for: r)
            guard box.intersects(dirty) else { continue }
            color.withAlphaComponent(r == hoveredFold ? 0.24 : 0.14).setFill()   // under the pointer it brightens
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            let dots = NSAttributedString(string: "⋯", attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: color.withAlphaComponent(0.7)])
            let size = dots.size()
            dots.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
        }
    }
}

extension CodeEditor {
    /// ⌥⌘[: the block the cursor's line opens, or else the innermost one around the cursor.
    public func fold() {
        let s = textView.string as NSString, i = textView.selectedRange().location
        var line = s.lineRange(for: NSRange(location: i, length: 0))
        if let r = Folds.region(of: line, in: s) { return textView.setFolded(r, true) }
        // Up to the lines that are less indented: the blocks around the cursor, innermost first.
        var limit = Folds.indent(line, in: s) ?? Int.max
        while line.location > 0, limit > 0 {
            line = s.lineRange(for: NSRange(location: line.location - 1, length: 0))
            guard let n = Folds.indent(line, in: s), n < limit else { continue }
            if let r = Folds.region(of: line, in: s), i <= NSMaxRange(r) { return textView.setFolded(r, true) }
            limit = n
        }
        NSSound.beep()
    }

    /// ⌥⌘]: the fold on the cursor's line, or around it.
    public func unfold() {
        let s = textView.string as NSString, i = textView.selectedRange().location
        let line = s.lineRange(for: NSRange(location: i, length: 0))
        guard let f = textView.folds.fold(at: MultiCursor.lineEnd(s, line.location)) ?? textView.folds.fold(at: i) else { return NSSound.beep() }
        textView.setFolded(f, false)
    }

    public func unfoldAll() { textView.folds.removeAll().forEach { textView.relayOut($0) } }

    /// A click on the gutter's chevron: the line's block folds, or opens.
    func toggleFold(line: NSRange) {
        let s = textView.string as NSString
        if let f = textView.folds.fold(at: MultiCursor.lineEnd(s, line.location)) { return textView.setFolded(f, false) }
        if let r = Folds.region(of: line, in: s) { textView.setFolded(r, true) }
    }
}
