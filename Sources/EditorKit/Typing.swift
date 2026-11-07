import AppKit

/// What typing does beyond putting the text in: a new line indented like the one above, Tab and ⇧Tab on whole lines,
/// brackets and quotes in pairs.
@MainActor enum Typing {
    static let closers: [unichar: unichar] = [40: 41, 91: 93, 123: 125, 34: 34, 39: 39, 96: 96]   // () [] {} "" '' ``

    /// A new line at every cursor, indented as its line (no more than the cursor's column: Return inside the indent
    /// doesn't double it); one level more after an opening bracket (and after `:` where that opens a block). Between a
    /// pair, the closer goes to a line of its own below the cursor.
    static func newline(_ tv: EditorTextView) {
        let string = tv.string as NSString
        let cs = tv.cursors, br = tv.lineBreak
        var carets: [Int] = []
        let texts = cs.map { cursor -> String in
            let line = string.lineRange(for: NSRange(location: cursor.location, length: 0))
            let lead = leading(string, line)
            let indent = string.substring(
                with: NSRange(location: lead.location, length: min(lead.length, cursor.location - line.location)))
            let prev = (line.location..<cursor.location).reversed().lazy.map { string.character(at: $0) }.first {
                $0 != 32 && $0 != 9
            }
            let opens = prev.map { [40, 91, 123].contains($0) || ($0 == 58 && tv.colonOpensBlock) } ?? false   // ( [ { and :
            let next = NSMaxRange(cursor) < string.length ? string.character(at: NSMaxRange(cursor)) : nil
            let first = br + indent + (opens ? tv.indentUnit : "")
            carets.append((first as NSString).length)
            guard opens, let prev, let next, closers[prev] == next else { return first }
            return first + br + indent
        }
        tv.replace(cs, with: texts, caret: carets)
    }

    /// Tab: the indent at each cursor, or every touched line one level in when a selection spans lines; ⇧Tab: one out.
    static func tab(_ tv: EditorTextView, back: Bool) {
        let string = tv.string as NSString
        if back || tv.cursors.contains(where: { string.substring(with: $0).contains("\n") }) {
            return shift(tv, out: back)
        }
        let cs = tv.cursors
        tv.replace(cs, with: cs.map { _ in tv.indentUnit })
    }

    /// ⌘] / ⌘[ and Tab on a selection: the lines the cursors touch, one level in or out; the selections stay on them.
    static func shift(_ tv: EditorTextView, out: Bool) {
        let string = tv.string as NSString
        let unit = (tv.indentUnit as NSString).length
        let edits: [(NSRange, String)] = lines(tv.cursors, in: string).compactMap { line in
            let lead = leading(string, line)
            if out {
                let removed = string.substring(with: lead).hasPrefix("\t") ? 1 : min(lead.length, unit)
                return removed > 0 ? (NSRange(location: line.location, length: removed), "") : nil
            }
            return lead.length == line.length - lineBreak(string, line)
                ? nil : (NSRange(location: line.location, length: 0), tv.indentUnit)   // not blank lines
        }
        tv.replace(edits.map(\.0), with: edits.map(\.1), keep: true)
    }

    /// An opening bracket or quote typed at the one cursor comes with its closer, or wraps the selection; a closer typed
    /// just before the same closer steps over it. True when done here.
    static func pairs(_ tv: EditorTextView, _ typed: String) -> Bool {
        let units = Array(typed.utf16)
        guard units.count == 1, tv.cursors.count == 1 else { return false }
        let character = units[0], string = tv.string as NSString, selection = tv.selectedRange()
        let next = NSMaxRange(selection) < string.length ? string.character(at: NSMaxRange(selection)) : nil
        if selection.length == 0, next == character, closers.values.contains(character) {
            tv.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        }
        guard let close = closers[character] else { return false }
        let open = String(utf16CodeUnits: [character], count: 1), shut = String(utf16CodeUnits: [close], count: 1)
        if selection.length > 0 {
            tv.replace([selection], with: [open + string.substring(with: selection) + shut])
            tv.setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
            return true
        }
        let word = CharacterSet.alphanumerics
        let prev = selection.location > 0 ? UnicodeScalar(string.character(at: selection.location - 1)) : nil
        // Before a space, a closer, punctuation or the end; a quote not right after a letter (the ' in don't).
        guard next.map({ [9, 10, 13, 32, 41, 93, 125, 44, 59, 58].contains($0) }) ?? true,
            close != character || !(prev.map(word.contains) ?? false)
        else { return false }
        tv.replace([selection], with: [open + shut], caret: [1])
        return true
    }

    /// ⌫ between a pair just typed, `(|)`: both go. True when done here.
    static func unpair(_ tv: EditorTextView) -> Bool {
        let string = tv.string as NSString, selection = tv.selectedRange()
        guard tv.cursors.count == 1, selection.length == 0, selection.location > 0, selection.location < string.length,
            closers[string.character(at: selection.location - 1)] == string.character(at: selection.location)
        else { return false }
        tv.replace([NSRange(location: selection.location - 1, length: 2)], with: [""])
        return true
    }

    // MARK: Lines

    /// The lines under the ranges, each once, top to bottom; a selection ending at a line's start leaves that line out.
    static func lines(_ ranges: [NSRange], in string: NSString) -> [NSRange] {
        var out: [NSRange] = []
        for range in ranges {
            let end =
                range.length > 0 && string.character(at: NSMaxRange(range) - 1) == 10
                ? NSMaxRange(range) - 1 : NSMaxRange(range)
            var at = string.lineRange(for: NSRange(location: range.location, length: 0)).location
            repeat {
                let line = string.lineRange(for: NSRange(location: at, length: 0))
                if out.last.map({ $0.location < line.location }) ?? true { out.append(line) }
                at = NSMaxRange(line)
            } while at <= end && at < string.length
        }
        return out
    }

    /// The spaces and tabs a line starts with.
    static func leading(_ string: NSString, _ line: NSRange) -> NSRange {
        var count = 0
        while count < line.length, [9, 32].contains(string.character(at: line.location + count)) { count += 1 }
        return NSRange(location: line.location, length: count)
    }

    /// How long the line's ending is (0 for a last line without one, 2 for \r\n).
    static func lineBreak(_ string: NSString, _ line: NSRange) -> Int {
        var end = 0, contentsEnd = 0
        string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: line)
        return end - contentsEnd
    }
}
