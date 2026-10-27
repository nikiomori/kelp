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
        let free = Self.occurrences(of: s.substring(with: last), in: s).filter { !sels.contains($0) }
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
        tv.setCursors(Self.occurrences(of: s.substring(with: r), in: s))
    }

    /// ⇧⌘K: the lines the selections touch, in one undo.
    public func deleteLines() {
        let s = textView.string as NSString
        let blocks = Self.lineBlocks(textView.cursors, in: s).map { b in
            // The last line has no newline of its own: take the one before it, or an empty line stays behind.
            let last = NSMaxRange(b) == s.length && b.location > 0 && s.character(at: NSMaxRange(b) - 1) != 10
            return last ? NSRange(location: b.location - 1, length: b.length + 1) : b
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
            return (text as NSString).hasSuffix("\n") ? text : down ? "\n" + text : text + "\n"
        }
        tv.replace(blocks.map { NSRange(location: down ? NSMaxRange($0) : $0.location, length: 0) }, with: copies)
        let lengths = copies.map { ($0 as NSString).length }
        tv.setCursors(sels.map { r in
            let i = blocks.lastIndex { $0.location <= r.location } ?? 0
            return NSRange(location: r.location + lengths[..<i].reduce(0, +) + (down ? lengths[i] : 0), length: r.length)
        })
    }

    /// ⌘/: the touched lines commented out with the language's line comment, or back in when they all are.
    public func toggleComment() {
        let mark = language.lineCommentString.isEmpty ? "//" : language.lineCommentString
        let s = textView.string as NSString
        let lines = Typing.lines(textView.cursors, in: s).filter { Typing.leading(s, $0).length < $0.length - Typing.lineBreak(s, $0) }
        guard !lines.isEmpty else { return }
        let starts = lines.map { NSMaxRange(Typing.leading(s, $0)) }
        let n = (mark as NSString).length
        func head(_ i: Int) -> String { s.substring(with: NSRange(location: i, length: min(n + 1, s.length - i))) }
        let commented = starts.allSatisfy { head($0).hasPrefix(mark) }
        let edits: [(NSRange, String)]
        if commented {
            edits = starts.map { i in
                let spaced = head(i).hasPrefix(mark + " ")
                return (NSRange(location: i, length: n + (spaced ? 1 : 0)), "")
            }
        } else {   // at the block's least indent, so the marks line up
            let column = zip(lines, starts).map { $1 - $0.location }.min() ?? 0
            edits = lines.map { (NSRange(location: $0.location + column, length: 0), mark + " ") }
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

    static func occurrences(of needle: String, in s: NSString) -> [NSRange] {
        var out: [NSRange] = [], from = 0
        while from < s.length {
            let r = s.range(of: needle, options: .literal, range: NSRange(location: from, length: s.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            out.append(r); from = NSMaxRange(r)
        }
        return out
    }

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
