import AppKit
import DesignKit

/// Folding by indentation, as VS Code does for most languages. A line whose next lines go in further can hide them
/// (from its own end to the end of the last line further in), shown as a ⋯ capsule. The line that comes back out (a
/// closing `}`) stays. The hidden characters get null glyphs, so the text, its undo and the find bar don't change.
final class Folds: @unchecked Sendable {   // used on the main thread only, where the layout manager asks for glyphs
    /// The folded ranges, top to bottom, not overlapping.
    private(set) var hidden: [NSRange] = []

    var isEmpty: Bool { hidden.isEmpty }

    /// The fold hiding `location`.
    func fold(at location: Int) -> NSRange? {
        let lo = hidden.partitionPoint { NSMaxRange($0) <= location }
        return lo < hidden.count && hidden[lo].location <= location ? hidden[lo] : nil
    }

    func intersects(_ range: NSRange) -> Bool { hidden.contains { NSIntersectionRange($0, range).length > 0 } }

    /// Folds `range`. A fold inside it goes, because it's hidden anyway; when a fold around it exists, that one stays
    /// and this one isn't added.
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

    /// Called for an edit about to be made (ranges top to bottom, with new lengths). A fold it reaches into opens, and
    /// the folds after it move. Returns the folds that opened, where they will be.
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

    /// What folding `line` hides: from its end to the end of the last following line that's further in. Nil when the
    /// next non-blank line isn't further in.
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
    /// Folded characters get null glyphs, with no width and no line of their own.
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

    /// A line is the font's height and `CodeEditor.lineExtra`, with the text in its middle.
    public nonisolated func layoutManager(
        _ lm: NSLayoutManager, shouldSetLineFragmentRect rect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in container: NSTextContainer, forGlyphRange range: NSRange
    ) -> Bool {
        rect.pointee.size.height += CodeEditor.lineExtra
        used.pointee.size.height += CodeEditor.lineExtra
        baselineOffset.pointee += CodeEditor.lineExtra / 2
        if let char = ghostRoom.char,
            NSLocationInRange(char, lm.characterRange(forGlyphRange: range, actualGlyphRange: nil))
        {
            rect.pointee.size.height += ghostRoom.height
            used.pointee.size.height += ghostRoom.height
        }
        return true
    }
    // swiftlint:enable function_parameter_count

    /// Folds `range` (or opens it) and lays it out again.
    func setFolded(_ range: NSRange, _ on: Bool) {
        if on { folds.add(range) } else { folds.remove(range) }
        if !on, range == hoveredFold { hoveredFold = nil }   // its ⋯ is gone
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

    /// Fades the hover fill in over the hovered fold's ⋯, or out, as a control's fill does.
    func showFoldHover() {
        if foldPlate.superview !== self { addSubview(foldPlate) }
        if let hoveredFold {
            let box = capsule(for: hoveredFold)
            foldPlate.frame = box
            foldPlate.layer?.cornerRadius = box.height / 2
        }
        foldPlate.fadeBackground(to: hoveredFold == nil ? nil : .fillHover)
    }

    func drawCapsules(in dirty: NSRect) {
        guard !folds.isEmpty else { return }
        let color = textColor ?? .labelColor
        for fold in folds.hidden {
            let box = capsule(for: fold)
            guard box.intersects(dirty) else { continue }
            color.withAlphaComponent(0.14).setFill()   // under the pointer, `foldPlate` brightens it
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
    /// ⌥⌘[ folds the block the cursor's line opens, or else the innermost block around the cursor.
    public func fold() {
        let string = textView.string as NSString, caret = textView.selectedRange().location
        var line = string.lineRange(for: NSRange(location: caret, length: 0))
        if let region = foldRegion(line, in: string) { return textView.setFolded(region, true) }
        // Goes up to the lines that are less indented, which open the blocks around the cursor, innermost first.
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

    /// ⌥⌘] opens the fold on the cursor's line, or around it.
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

    /// A click on the gutter's chevron folds the line's block, or opens it.
    func toggleFold(line: NSRange) {
        let string = textView.string as NSString
        if let folded = textView.folds.fold(at: MultiCursor.lineEnd(string, line.location)) {
            return textView.setFolded(folded, false)
        }
        if let region = foldRegion(line, in: string) { textView.setFolded(region, true) }
    }
}

/// The empty line after a final newline is as tall as the lines above it. The typesetter sets that line without asking
/// the delegate, which gives every other line its height.
final class EditorLayoutManager: NSLayoutManager {
    override func setExtraLineFragmentRect(
        _ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer
    ) {
        var fragmentRect = fragmentRect, usedRect = usedRect
        if !fragmentRect.isEmpty {
            fragmentRect.size.height += CodeEditor.lineExtra
            usedRect.size.height += CodeEditor.lineExtra
        }
        super.setExtraLineFragmentRect(fragmentRect, usedRect: usedRect, textContainer: container)
    }
}

/// The fill over a hovered fold's ⋯: a view of its own, so the fill fades in and out as a control's does. The pointer
/// goes through it to the text.
final class FoldPlate: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
