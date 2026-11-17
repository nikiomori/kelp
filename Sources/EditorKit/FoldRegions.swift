import AppKit
@preconcurrency import SwiftTreeSitter

/// What a fold hides: a section someone marked, else what the parse tree says the line opens, else what's indented
/// under it.
extension CodeEditor {
    /// Past this many lines, Fold All goes by the first ones only, because a file that long isn't read by folding it.
    private static let mostLinesFolded = 20_000

    func foldRegion(_ line: NSRange, in string: NSString) -> NSRange? {
        Folds.section(line, in: string, markdown: isMarkdown) ?? syntaxRegion(line, in: string)
            ?? Folds.region(of: line, in: string)
    }

    /// The biggest node starting on `line` and ending on a later one, leaving aside the file's own root. A closing
    /// bracket alone on its line stays out, as with indentation.
    private func syntaxRegion(_ line: NSRange, in string: NSString) -> NSRange? {
        var at = line.location
        while at < NSMaxRange(line), [32, 9].contains(string.character(at: at)) { at += 1 }
        guard at < NSMaxRange(line), string.character(at: at) != 10,
            var node = highlighter?.tree?.rootNode?.descendant(in: UInt32(at * 2)..<UInt32(at * 2 + 2))
        else { return nil }
        var best: NSRange?
        while let up = node.parent {
            let nodeRange = node.range
            if nodeRange.location < line.location { break }
        // A run of statements starts here too, but when the next statement is under this line, the line didn't open
        // it.
            let next = node.child(at: 1)?.range.location ?? nodeRange.location
            let list =
                next >= NSMaxRange(line)
                && Folds.indent(string.lineRange(for: NSRange(location: next, length: 0)), in: string)
                    == Folds.indent(line, in: string)
            if NSMaxRange(nodeRange) > NSMaxRange(line), !list { best = nodeRange }
            node = up
        }
        guard let best else { return nil }
        var last = string.lineRange(for: NSRange(location: NSMaxRange(best) - 1, length: 0))
        let closing = string.substring(with: last).trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy {
            ")]}".contains($0)
        }
        if closing, last.location > NSMaxRange(line) {
            last = string.lineRange(for: NSRange(location: last.location - 1, length: 0))
        }
        let start = MultiCursor.lineEnd(string, line.location), end = MultiCursor.lineEnd(string, last.location)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Fold All, or with `level` 2 or 3, folds only what's that deep and leaves the rest open.
    public func foldAll(level: Int = 1) {
        let string = textView.string as NSString
        var ends: [Int] = [], at = 0, lines = 0, found: [NSRange] = []
        while at < string.length, lines < Self.mostLinesFolded {
            let line = string.lineRange(for: NSRange(location: at, length: 0))
            ends.removeAll { $0 <= line.location }
            if let region = foldRegion(line, in: string) {
                ends.append(NSMaxRange(region))
                if ends.count == level { found.append(region) }
            }
            at = NSMaxRange(line)
            lines += 1
        }
        found.forEach { textView.setFolded($0, true) }
    }
}

extension Folds {
    /// A section marked in the text: `// MARK:` to the next one, `#region` to its `#endregion`, or a Markdown heading
    /// to the next heading that isn't under it.
    static func section(_ line: NSRange, in string: NSString, markdown: Bool) -> NSRange? {
        let text = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        let isMark = { (lineText: String) in lineText.hasPrefix("// MARK:") || lineText.hasPrefix("#pragma mark") }
        let trimmed = { (range: NSRange) in
            string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ends: (NSRange) -> Bool
        var includesEnd = false
        if isMark(text) {
            ends = { isMark(trimmed($0)) }
        } else if text.contains("#region") {
            ends = { trimmed($0).contains("#endregion") }
            includesEnd = true
        } else if markdown, let level = headingLevel(line, in: string) {
            // A heading is read character by character, because a top heading's section runs to the end of the file,
            // line after line.
            ends = { (headingLevel($0, in: string) ?? 7) <= level }
        } else {
            return nil
        }
        var at = NSMaxRange(line), last: NSRange?
        while at < string.length {
            let current = string.lineRange(for: NSRange(location: at, length: 0))
            if ends(current) {
                if includesEnd { last = current }
                break
            }
            last = current
            at = NSMaxRange(current)
        }
        // Blank lines before what comes next stay out of it.
        while let tail = last, tail.location > NSMaxRange(line),
            string.substring(with: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            last = string.lineRange(for: NSRange(location: tail.location - 1, length: 0))
        }
        guard let last else { return nil }
        let start = MultiCursor.lineEnd(string, line.location), end = MultiCursor.lineEnd(string, last.location)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// A Markdown heading's level (1–6): hashes after the line's indent, a space, then something. Nil for any other
    /// line.
    static func headingLevel(_ line: NSRange, in string: NSString) -> Int? {
        let end = NSMaxRange(line)
        var at = line.location
        func blank(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        while at < end, blank(string.character(at: at)) { at += 1 }
        let hashes = at
        while at < end, string.character(at: at) == 35 { at += 1 }
        let level = at - hashes
        guard (1...6).contains(level), at < end, string.character(at: at) == 32 else { return nil }
        while at < end, blank(string.character(at: at)) { at += 1 }
        return at < end ? level : nil
    }
}
