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
    /// Compared a piece at a time with memcmp: two copies of a 5 MB text, one per tab following the disk, took their time.
    static func changed(_ before: NSString, _ after: NSString) -> (old: NSRange, new: NSRange) {
        let oldCount = before.length, newCount = after.length, shorter = min(oldCount, newCount)
        let piece = 4096
        var a = [unichar](repeating: 0, count: piece), b = [unichar](repeating: 0, count: piece)
        /// How many of the `n` characters at `x` in `before` and `y` in `after` match, from the start (or the end).
        func matching(_ x: Int, _ y: Int, _ n: Int, fromEnd: Bool) -> Int {
            before.getCharacters(&a, range: NSRange(location: x, length: n))
            after.getCharacters(&b, range: NSRange(location: y, length: n))
            if memcmp(a, b, n * MemoryLayout<unichar>.size) == 0 { return n }
            var same = 0
            while fromEnd ? a[n - 1 - same] == b[n - 1 - same] : a[same] == b[same] { same += 1 }
            return same
        }
        var head = 0, tail = 0
        while head < shorter {
            let n = min(piece, shorter - head), same = matching(head, head, n, fromEnd: false)
            head += same
            if same < n { break }
        }
        while tail < shorter - head {
            let n = min(piece, shorter - head - tail)
            let same = matching(oldCount - tail - n, newCount - tail - n, n, fromEnd: true)
            tail += same
            if same < n { break }
        }
        if head > 0, UTF16.isLeadSurrogate(before.character(at: head - 1)) { head -= 1 }
        if tail > 0, UTF16.isTrailSurrogate(before.character(at: oldCount - tail)) { tail -= 1 }
        return (
            NSRange(location: head, length: oldCount - head - tail),
            NSRange(location: head, length: newCount - head - tail)
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
}
