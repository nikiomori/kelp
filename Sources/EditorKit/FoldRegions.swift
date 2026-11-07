import AppKit
@preconcurrency import SwiftTreeSitter

/// What a fold hides: a section someone marked, else what the parse tree says the line opens, else what's indented under it.
extension CodeEditor {
    /// Past this many lines Fold All goes by the first ones only: a file that long isn't read by folding it.
    private static let mostLinesFolded = 20_000

    func foldRegion(_ line: NSRange, in s: NSString) -> NSRange? {
        Folds.section(line, in: s, markdown: isMarkdown) ?? syntaxRegion(line, in: s) ?? Folds.region(of: line, in: s)
    }

    /// The biggest node starting on `line` and ending on a later one, the file's own root aside. A closing bracket alone on
    /// its line stays out, as with indentation.
    private func syntaxRegion(_ line: NSRange, in s: NSString) -> NSRange? {
        var at = line.location
        while at < NSMaxRange(line), [32, 9].contains(s.character(at: at)) { at += 1 }
        guard at < NSMaxRange(line), s.character(at: at) != 10,
            var node = highlighter?.tree?.rootNode?.descendant(in: UInt32(at * 2)..<UInt32(at * 2 + 2))
        else { return nil }
        var best: NSRange?
        while let up = node.parent {
            let r = node.range
            if r.location < line.location { break }
            // A run of statements starts here too, but the next one is under this line, not opened by it.
            let next = node.child(at: 1)?.range.location ?? r.location
            let list =
                next >= NSMaxRange(line)
                && Folds.indent(s.lineRange(for: NSRange(location: next, length: 0)), in: s)
                    == Folds.indent(line, in: s)
            if NSMaxRange(r) > NSMaxRange(line), !list { best = r }
            node = up
        }
        guard let best else { return nil }
        var last = s.lineRange(for: NSRange(location: NSMaxRange(best) - 1, length: 0))
        let closing = s.substring(with: last).trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy {
            ")]}".contains($0)
        }
        if closing, last.location > NSMaxRange(line) {
            last = s.lineRange(for: NSRange(location: last.location - 1, length: 0))
        }
        let start = MultiCursor.lineEnd(s, line.location), end = MultiCursor.lineEnd(s, last.location)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Fold All, or (`level` 2, 3) what's that deep and leaves the rest open.
    public func foldAll(level: Int = 1) {
        let s = textView.string as NSString
        var ends: [Int] = [], at = 0, lines = 0, found: [NSRange] = []
        while at < s.length, lines < Self.mostLinesFolded {
            let line = s.lineRange(for: NSRange(location: at, length: 0))
            ends.removeAll { $0 <= line.location }
            if let r = foldRegion(line, in: s) {
                ends.append(NSMaxRange(r))
                if ends.count == level { found.append(r) }
            }
            at = NSMaxRange(line)
            lines += 1
        }
        found.forEach { textView.setFolded($0, true) }
    }
}

extension Folds {
    /// A section marked in the text: `// MARK:` to the next, `#region` to its `#endregion`, a Markdown heading to the next
    /// that isn't under it.
    static func section(_ line: NSRange, in s: NSString, markdown: Bool) -> NSRange? {
        let text = s.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        let isMark = { (t: String) in t.hasPrefix("// MARK:") || t.hasPrefix("#pragma mark") }
        let heading = { (t: String) -> Int? in
            let n = t.prefix { $0 == "#" }.count
            return n > 0 && n <= 6 && t.dropFirst(n).hasPrefix(" ") ? n : nil
        }
        let ends: (String) -> Bool
        var includesEnd = false
        if isMark(text) {
            ends = isMark
        } else if text.contains("#region") {
            ends = { $0.contains("#endregion") }
            includesEnd = true
        } else if markdown, let level = heading(text) {
            ends = { (heading($0) ?? 7) <= level }
        } else {
            return nil
        }
        var i = NSMaxRange(line), last: NSRange?
        while i < s.length {
            let l = s.lineRange(for: NSRange(location: i, length: 0))
            if ends(s.substring(with: l).trimmingCharacters(in: .whitespacesAndNewlines)) {
                if includesEnd { last = l }
                break
            }
            last = l
            i = NSMaxRange(l)
        }
        // Blank lines before what comes next stay out of it.
        while let l = last, l.location > NSMaxRange(line),
            s.substring(with: l).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            last = s.lineRange(for: NSRange(location: l.location - 1, length: 0))
        }
        guard let last else { return nil }
        let start = MultiCursor.lineEnd(s, line.location), end = MultiCursor.lineEnd(s, last.location)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}
