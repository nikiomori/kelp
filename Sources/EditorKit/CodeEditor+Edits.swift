import AppKit

/// VS Code's editing commands. Their keys are the Selection menu's, on only while an editor has the focus (`focused`);
/// a key the shell uses too (⌘D, ⌘[ ⌘]) reaches the editor's first through the file tab (EditorBox).
extension CodeEditor {
    /// The editor whose text view has the focus in the key window.
    public static var focused: CodeEditor? {
        all.allObjects.first { e in
            let tv = e.textView
            return tv.window?.firstResponder === tv && (NSApp.keyWindow ?? tv.window) === tv.window
        }
    }

    /// ⌘D: the word at each cursor; then the next occurrence of the selected text joins the selections, past the
    /// last one and then from the top.
    public func addNextOccurrence() {
        let tv = textView, s = tv.string as NSString, sels = tv.cursors
        if sels.contains(where: { $0.length == 0 }) {
            return tv.setCursors(sels.map { $0.length > 0 ? $0 : Self.word(at: $0.location, in: s) })
        }
        guard let last = sels.last else { return }
        let free = Self.occurrences(of: s.substring(with: last), in: s, wholeWords: sels.allSatisfy { Self.isWord($0, in: s) })
            .filter { !sels.contains($0) }
        guard let next = free.first(where: { $0.location >= NSMaxRange(last) }) ?? free.first else { return }
        tv.setCursors(sels + [next])
        tv.scrollRangeToVisible(next)
    }

    /// ⇧⌘L: every occurrence of the selected text (or of the word at the cursor).
    public func selectAllOccurrences() {
        let tv = textView, s = tv.string as NSString
        guard let first = tv.cursors.first else { return }
        let r = first.length > 0 ? first : Self.word(at: first.location, in: s)
        guard r.length > 0 else { return }
        tv.setCursors(Self.occurrences(of: s.substring(with: r), in: s, wholeWords: Self.isWord(r, in: s)))
    }

    /// ⇧⌘K: the lines the selections touch, in one undo.
    public func deleteLines() {
        let s = textView.string as NSString
        let blocks = Self.lineBlocks(textView.cursors, in: s).map { b in
            // The last line has no line break of its own: take the one before it (\r\n whole), or an empty line stays.
            guard NSMaxRange(b) == s.length, b.location > 0, s.character(at: NSMaxRange(b) - 1) != 10 else { return b }
            let n = b.location > 1 && s.character(at: b.location - 2) == 13 ? 2 : 1
            return NSRange(location: b.location - n, length: b.length + n)
        }
        textView.replace(blocks, with: blocks.map { _ in "" })
    }

    /// ⌥↓ / ⌥↑: the selected lines trade places with the line below or above, selections along.
    public func moveLines(down: Bool) {
        let tv = textView, s = tv.string as NSString, sels = tv.cursors
        let blocks = Self.lineBlocks(sels, in: s)
        // Each block with its neighbour, as one replacement; blocks are a line apart at least, so the swaps don't meet.
        let swaps = blocks.map { b -> (range: NSRange, text: String, shift: Int)? in
            guard down ? NSMaxRange(b) < s.length : b.location > 0 else { return nil }
            let other = s.lineRange(for: NSRange(location: down ? NSMaxRange(b) : b.location - 1, length: 0))
            var (top, bottom) = down ? (s.substring(with: other), s.substring(with: b)) : (s.substring(with: b), s.substring(with: other))
            if !(top as NSString).hasSuffix("\n") {   // the last line moves up: its line break goes with the line now above it
                top += bottom.hasSuffix("\r\n") ? "\r\n" : "\n"; bottom.removeLast()
            }
            return (NSUnionRange(b, other), top + bottom, down ? (top as NSString).length : -other.length)
        }
        let done = swaps.compactMap { $0 }
        tv.replace(done.map(\.range), with: done.map(\.text))
        tv.setCursors(sels.map { r in
            let i = blocks.lastIndex { $0.location <= r.location } ?? 0
            return NSRange(location: r.location + (swaps[i]?.shift ?? 0), length: r.length)
        })
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    /// ⇧⌥↓ / ⇧⌥↑: the selected lines once more, below or above; the selections move to the copy below, or stay on the
    /// one above, as in VS Code.
    public func copyLines(down: Bool) {
        let tv = textView, s = tv.string as NSString, sels = tv.cursors
        let blocks = Self.lineBlocks(sels, in: s)
        let copies = blocks.map { b -> String in
            let text = s.substring(with: b)
            return (text as NSString).hasSuffix("\n") ? text : down ? tv.lineBreak + text : text + tv.lineBreak
        }
        tv.replace(blocks.map { NSRange(location: down ? NSMaxRange($0) : $0.location, length: 0) }, with: copies)
        let lengths = copies.map { ($0 as NSString).length }
        tv.setCursors(sels.map { r in
            let i = blocks.lastIndex { $0.location <= r.location } ?? 0
            return NSRange(location: r.location + lengths[..<i].reduce(0, +) + (down ? lengths[i] : 0), length: r.length)
        })
    }

    /// ⌘/: the touched lines commented out, or back in when they all are: with the language's line comment, else each
    /// line in its block comment (CSS, HTML).
    public func toggleComment() {
        let (open, close) = language.lineCommentString.isEmpty ? language.rangeCommentStrings : (language.lineCommentString, "")
        guard !open.isEmpty else { return NSSound.beep() }   // plain text
        let s = textView.string as NSString
        let lines = Typing.lines(textView.cursors, in: s).filter { Typing.leading(s, $0).length < $0.length - Typing.lineBreak(s, $0) }
        guard !lines.isEmpty else { return }
        let bodies = lines.map { l in NSRange(location: NSMaxRange(Typing.leading(s, l)), length: 0) }.enumerated().map { i, b in
            NSRange(location: b.location, length: NSMaxRange(lines[i]) - Typing.lineBreak(s, lines[i]) - b.location)   // after the indent
        }
        let texts = bodies.map { s.substring(with: $0) }
        if texts.allSatisfy({ $0.hasPrefix(open) && $0.hasSuffix(close) }) {
            var edits: [(NSRange, String)] = []
            for (b, t) in zip(bodies, texts) {
                let o = (open as NSString).length + (t.hasPrefix(open + " ") ? 1 : 0)
                edits.append((NSRange(location: b.location, length: o), ""))
                if !close.isEmpty {
                    let c = (close as NSString).length + (t.hasSuffix(" " + close) && t.count > open.count + close.count ? 1 : 0)
                    edits.append((NSRange(location: NSMaxRange(b) - c, length: c), ""))
                }
            }
            return textView.replace(edits.map(\.0), with: edits.map(\.1), keep: true)
        }
        // At the block's least indent, so the marks line up.
        let column = zip(lines, bodies).map { $1.location - $0.location }.min() ?? 0
        var edits: [(NSRange, String)] = []
        for (l, b) in zip(lines, bodies) {
            edits.append((NSRange(location: l.location + column, length: 0), open + " "))
            if !close.isEmpty { edits.append((NSRange(location: NSMaxRange(b), length: 0), " " + close)) }
        }
        textView.replace(edits.map(\.0), with: edits.map(\.1), keep: true)
    }

    /// ⌘] / ⌘[: the touched lines a level in or out.
    public func indent(out: Bool) { Typing.shift(textView, out: out) }

    // MARK: Text

    /// The identifier around `i` (letters, digits, `_`, `$`); empty when there is none.
    static func word(at i: Int, in s: NSString) -> NSRange {
        let ident = CharacterSet.alphanumerics.union(.init(charactersIn: "_$"))
        func isIdent(_ j: Int) -> Bool { j >= 0 && j < s.length && UnicodeScalar(s.character(at: j)).map(ident.contains) == true }
        var a = i, b = i
        while isIdent(a - 1) { a -= 1 }
        while isIdent(b) { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    /// Where `needle` is, case and all; with `wholeWords`, not where it's part of a longer word (`id` in `width`).
    static func occurrences(of needle: String, in s: NSString, wholeWords: Bool = false) -> [NSRange] {
        var out: [NSRange] = [], from = 0
        while from < s.length {
            let r = s.range(of: needle, options: .literal, range: NSRange(location: from, length: s.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            if !wholeWords || isWord(r, in: s) { out.append(r) }
            from = NSMaxRange(r)
        }
        return out
    }

    /// A whole word: `r` is the identifier around its start (⌘D from a caret picks one, and then looks for words alone).
    static func isWord(_ r: NSRange, in s: NSString) -> Bool { r.length > 0 && word(at: r.location, in: s) == r }

    /// Whole lines under the selections, overlapping ones merged, top to bottom. A selection that ends at the start of
    /// a line (a triple-click) doesn't take that line.
    static func lineBlocks(_ sels: [NSRange], in s: NSString) -> [NSRange] {
        let lines = sels.sorted { $0.location < $1.location }.map { r in
            s.lineRange(for: r.length > 0 && s.character(at: NSMaxRange(r) - 1) == 10 ? NSRange(location: r.location, length: r.length - 1) : r)
        }
        return lines.reduce(into: []) { out, l in
            if let p = out.last, l.location <= NSMaxRange(p) { out[out.count - 1] = NSUnionRange(p, l) } else { out.append(l) }
        }
    }
}
