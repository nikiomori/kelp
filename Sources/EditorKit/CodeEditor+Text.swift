import AppKit

// Reads of a text that need no view: whether it can be edited, its line breaks, its indent, what two versions don't share.

extension CodeEditor {
    /// Whether editing `text` keeps the window responsive.
    public static func canEdit(_ text: String) -> Bool {
        var contents = text
        guard contents.utf8.count <= readOnlyLimit else { return false }
        return contents.withUTF8 { buffer in
            guard var next = buffer.baseAddress else { return true }
            let end = next + buffer.count
            while end - next > longestEditableLine {
                guard let hit = memchr(next, 10, longestEditableLine) else { return false }
                next = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) + 1
            }
            return true
        }
    }

    /// Line breaks in `contents`, by memchr over its UTF-8 (a Swift loop over 5 MB took 150 ms in a debug build).
    static func breaks(in contents: String) -> Int {
        var contents = contents
        return contents.withUTF8 { buffer in
            guard var next = buffer.baseAddress else { return 0 }
            let end = next + buffer.count
            var count = 0
            while let hit = memchr(next, 10, end - next) {
                count += 1
                next = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) + 1
            }
            return count
        }
    }

    /// The middle two texts don't share: what's in `before`, what's in `after`. Never between a surrogate pair's halves.
    static func changed(_ before: NSString, _ after: NSString) -> (old: NSRange, new: NSRange) {
        var oldChars = [unichar](repeating: 0, count: before.length),
            newChars = [unichar](repeating: 0, count: after.length)
        before.getCharacters(&oldChars, range: NSRange(location: 0, length: before.length))
        after.getCharacters(&newChars, range: NSRange(location: 0, length: after.length))
        let shorter = min(oldChars.count, newChars.count)
        var head = 0, tail = 0
        while head < shorter, oldChars[head] == newChars[head] { head += 1 }
        while tail < shorter - head, oldChars[oldChars.count - 1 - tail] == newChars[newChars.count - 1 - tail] {
            tail += 1
        }
        if head > 0, UTF16.isLeadSurrogate(oldChars[head - 1]) { head -= 1 }
        if tail > 0, UTF16.isTrailSurrogate(oldChars[oldChars.count - tail]) { tail -= 1 }
        return (
            NSRange(location: head, length: oldChars.count - head - tail),
            NSRange(location: head, length: newChars.count - head - tail)
        )
    }

    public var selectedText: String? {
        let string = textView.string as NSString
        let parts = textView.cursors.filter { $0.length > 0 }.map { string.substring(with: $0) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 1-based lines of the first selection; a line selected with its line break (a triple-click) is that line alone.
    public var selectedLines: ClosedRange<Int>? {
        let selection = textView.selectedRange(), string = textView.string as NSString
        let end =
            selection.length > 0 && string.character(at: NSMaxRange(selection) - 1) == 10
            ? NSMaxRange(selection) - 1 : NSMaxRange(selection)
        return lineIndex.line(at: selection.location, in: string) + 1...lineIndex.line(at: end, in: string) + 1
    }

    /// 1-based line/column of the primary cursor.
    public var cursor: (line: Int, column: Int)? {
        lineIndex.position(of: textView.selectedRange().location, in: textView.string as NSString)
    }

    /// Primary selection in UTF-16 units.
    public var selectedRange: NSRange { textView.selectedRange() }

    /// Where the one selection's first line is on screen, in `view`'s coordinates; nil with no selection, several, or
    /// one scrolled out of sight.
    public var selectionRect: NSRect? {
        let selection = textView.selectedRange(), string = textView.string as NSString
        guard textView.cursors.count == 1, selection.length > 0, let lm = textView.layoutManager,
            let tc = textView.textContainer
        else { return nil }
        let line = NSIntersectionRange(
            selection, string.lineRange(for: NSRange(location: selection.location, length: 0)))
        let glyphs = lm.glyphRange(forCharacterRange: line.length > 0 ? line : selection, actualCharacterRange: nil)
        let box = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(
            dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let shown = textView.visibleRect.intersection(box)
        return shown.isEmpty ? nil : view.convert(shown, from: textView)
    }

    /// A tab when most indented lines start with one; two spaces when that's the smallest indent; else four.
    static func indentUnit(of text: String) -> String {
        var tabs = 0, spaces: [Int] = []
        for line in text.prefix(64_000).split(separator: "\n").prefix(500) {   // the start of a big file is enough
            if line.hasPrefix("\t") {
                tabs += 1
            } else if line.hasPrefix(" ") {
                spaces.append(line.prefix { $0 == " " }.count)
            }
        }
        if tabs > spaces.count { return "\t" }
        return spaces.min() == 2 ? "  " : "    "
    }
}
