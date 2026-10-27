import AppKit

/// What typing does beyond putting the text in: a new line indented like the one above, Tab and ⇧Tab on whole lines,
/// brackets and quotes in pairs.
@MainActor enum Typing {
    static let closers: [unichar: unichar] = [40: 41, 91: 93, 123: 125, 34: 34, 39: 39, 96: 96]   // () [] {} "" '' ``

    /// A new line at every cursor, indented as its line; one level more after an opening bracket (and after `:` where
    /// that opens a block). Between a pair, the closer goes to a line of its own below the cursor.
    static func newline(_ tv: EditorTextView) {
        let s = tv.string as NSString
        let cs = tv.cursors
        var carets: [Int] = []
        let texts = cs.map { r -> String in
            let line = s.lineRange(for: NSRange(location: r.location, length: 0))
            let indent = s.substring(with: leading(s, line))
            let prev = (line.location..<r.location).reversed().lazy.map { s.character(at: $0) }.first { $0 != 32 && $0 != 9 }
            let opens = prev.map { [40, 91, 123].contains($0) || ($0 == 58 && tv.colonOpensBlock) } ?? false   // ( [ { and :
            let next = NSMaxRange(r) < s.length ? s.character(at: NSMaxRange(r)) : nil
            let first = "\n" + indent + (opens ? tv.indentUnit : "")
            carets.append((first as NSString).length)
            guard opens, let prev, let next, closers[prev] == next else { return first }
            return first + "\n" + indent
        }
        tv.replace(cs, with: texts, caret: carets)
    }

    /// Tab: the indent at each cursor, or every touched line one level in when a selection spans lines; ⇧Tab: one out.
    static func tab(_ tv: EditorTextView, back: Bool) {
        let s = tv.string as NSString
        if back || tv.cursors.contains(where: { s.substring(with: $0).contains("\n") }) { return shift(tv, out: back) }
        let cs = tv.cursors
        tv.replace(cs, with: cs.map { _ in tv.indentUnit })
    }

    /// ⌘] / ⌘[ and Tab on a selection: the lines the cursors touch, one level in or out; the selections stay on them.
    static func shift(_ tv: EditorTextView, out: Bool) {
        let s = tv.string as NSString
        let unit = (tv.indentUnit as NSString).length
        let edits: [(NSRange, String)] = lines(tv.cursors, in: s).compactMap { line in
            let lead = leading(s, line)
            if out {
                let n = s.substring(with: lead).hasPrefix("\t") ? 1 : min(lead.length, unit)
                return n > 0 ? (NSRange(location: line.location, length: n), "") : nil
            }
            return lead.length == line.length - lineBreak(s, line) ? nil : (NSRange(location: line.location, length: 0), tv.indentUnit)   // not blank lines
        }
        tv.replace(edits.map(\.0), with: edits.map(\.1), keep: true)
    }

    /// An opening bracket or quote typed at the one cursor comes with its closer, or wraps the selection; a closer typed
    /// just before the same closer steps over it. True when done here.
    static func pairs(_ tv: EditorTextView, _ typed: String) -> Bool {
        let u = Array(typed.utf16)
        guard u.count == 1, tv.cursors.count == 1 else { return false }
        let c = u[0], s = tv.string as NSString, r = tv.selectedRange()
        let next = NSMaxRange(r) < s.length ? s.character(at: NSMaxRange(r)) : nil
        if r.length == 0, next == c, closers.values.contains(c) {
            tv.setSelectedRange(NSRange(location: r.location + 1, length: 0))
            return true
        }
        guard let close = closers[c] else { return false }
        let open = String(utf16CodeUnits: [c], count: 1), shut = String(utf16CodeUnits: [close], count: 1)
        if r.length > 0 {
            tv.replace([r], with: [open + s.substring(with: r) + shut])
            tv.setSelectedRange(NSRange(location: r.location + 1, length: r.length))
            return true
        }
        let word = CharacterSet.alphanumerics
        let prev = r.location > 0 ? UnicodeScalar(s.character(at: r.location - 1)) : nil
        // Before a space, a closer, punctuation or the end; a quote not right after a letter (the ' in don't).
        guard next.map({ [9, 10, 13, 32, 41, 93, 125, 44, 59, 58].contains($0) }) ?? true,
              close != c || !(prev.map(word.contains) ?? false) else { return false }
        tv.replace([r], with: [open + shut], caret: [1])
        return true
    }

    /// ⌫ between a pair just typed, `(|)`: both go. True when done here.
    static func unpair(_ tv: EditorTextView) -> Bool {
        let s = tv.string as NSString, r = tv.selectedRange()
        guard tv.cursors.count == 1, r.length == 0, r.location > 0, r.location < s.length,
              closers[s.character(at: r.location - 1)] == s.character(at: r.location) else { return false }
        tv.replace([NSRange(location: r.location - 1, length: 2)], with: [""])
        return true
    }

    // MARK: Lines

    /// The lines under the ranges, each once, top to bottom; a selection ending at a line's start leaves that line out.
    static func lines(_ ranges: [NSRange], in s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            let end = r.length > 0 && s.character(at: NSMaxRange(r) - 1) == 10 ? NSMaxRange(r) - 1 : NSMaxRange(r)
            var i = s.lineRange(for: NSRange(location: r.location, length: 0)).location
            repeat {
                let line = s.lineRange(for: NSRange(location: i, length: 0))
                if out.last.map({ $0.location < line.location }) ?? true { out.append(line) }
                i = NSMaxRange(line)
            } while i <= end && i < s.length
        }
        return out
    }

    /// The spaces and tabs a line starts with.
    static func leading(_ s: NSString, _ line: NSRange) -> NSRange {
        var n = 0
        while n < line.length, [9, 32].contains(s.character(at: line.location + n)) { n += 1 }
        return NSRange(location: line.location, length: n)
    }

    /// How long the line's ending is (0 for a last line without one, 2 for \r\n).
    static func lineBreak(_ s: NSString, _ line: NSRange) -> Int {
        var end = 0, contentsEnd = 0
        s.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: line)
        return end - contentsEnd
    }
}
