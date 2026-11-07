import AppKit

/// VS Code's editing commands. Their keys are the Selection menu's, on only while an editor has the focus (`focused`);
/// a key the shell uses too (⌘D, ⌘[ ⌘]) reaches the editor's first through the file tab (EditorBox).
extension CodeEditor {
    /// The editor whose text view has the focus in the key window.
    public static var focused: CodeEditor? {
        all.allObjects.first { editor in
            let tv = editor.textView
            return tv.window?.firstResponder === tv && (NSApp.keyWindow ?? tv.window) === tv.window
        }
    }

    /// ⌘D: the word at each cursor; then the next occurrence of the selected text joins the selections, past the
    /// last one and then from the top.
    public func addNextOccurrence() {
        let tv = textView, string = tv.string as NSString, sels = tv.cursors
        if sels.contains(where: { $0.length == 0 }) {
            return tv.setCursors(sels.map { $0.length > 0 ? $0 : Self.word(at: $0.location, in: string) })
        }
        guard let last = sels.last else { return }
        let free = Self.occurrences(
            of: string.substring(with: last), in: string, wholeWords: sels.allSatisfy { Self.isWord($0, in: string) }
        )
        .filter { !sels.contains($0) }
        guard let next = free.first(where: { $0.location >= NSMaxRange(last) }) ?? free.first else { return }
        tv.setCursors(sels + [next])
        tv.scrollRangeToVisible(next)
    }

    /// ⇧⌘L: every occurrence of the selected text (or of the word at the cursor).
    public func selectAllOccurrences() {
        let tv = textView, string = tv.string as NSString
        guard let first = tv.cursors.first else { return }
        let target = first.length > 0 ? first : Self.word(at: first.location, in: string)
        guard target.length > 0 else { return }
        tv.setCursors(
            Self.occurrences(
                of: string.substring(with: target), in: string, wholeWords: Self.isWord(target, in: string)))
    }

    /// ⇧⌘K: the lines the selections touch, in one undo.
    public func deleteLines() {
        let string = textView.string as NSString
        let blocks = Self.lineBlocks(textView.cursors, in: string).map { block in
            // The last line has no line break of its own: take the one before it (\r\n whole), or an empty line stays.
            guard NSMaxRange(block) == string.length, block.location > 0,
                string.character(at: NSMaxRange(block) - 1) != 10
            else { return block }
            let breakLength = block.location > 1 && string.character(at: block.location - 2) == 13 ? 2 : 1
            return NSRange(location: block.location - breakLength, length: block.length + breakLength)
        }
        textView.replace(blocks, with: blocks.map { _ in "" })
    }

    /// ⌥↓ / ⌥↑: the selected lines trade places with the line below or above, selections along.
    public func moveLines(down: Bool) {
        let tv = textView, string = tv.string as NSString, sels = tv.cursors
        let blocks = Self.lineBlocks(sels, in: string)
        // Each block with its neighbour, as one replacement; blocks are a line apart at least, so the swaps don't meet.
        let swaps = blocks.map { block -> (range: NSRange, text: String, shift: Int)? in
            guard down ? NSMaxRange(block) < string.length : block.location > 0 else { return nil }
            let other = string.lineRange(
                for: NSRange(location: down ? NSMaxRange(block) : block.location - 1, length: 0))
            var (top, bottom) =
                down
                ? (string.substring(with: other), string.substring(with: block))
                : (string.substring(with: block), string.substring(with: other))
            if !(top as NSString).hasSuffix("\n") {   // the last line moves up: its line break goes with the line now above it
                top += bottom.hasSuffix("\r\n") ? "\r\n" : "\n"
                bottom.removeLast()
            }
            return (NSUnionRange(block, other), top + bottom, down ? (top as NSString).length : -other.length)
        }
        let done = swaps.compactMap { $0 }
        tv.replace(done.map(\.range), with: done.map(\.text))
        tv.setCursors(
            sels.map { selection in
                let index = blocks.lastIndex { $0.location <= selection.location } ?? 0
                return NSRange(location: selection.location + (swaps[index]?.shift ?? 0), length: selection.length)
            })
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    /// ⇧⌥↓ / ⇧⌥↑: the selected lines once more, below or above; the selections move to the copy below, or stay on the
    /// one above, as in VS Code.
    public func copyLines(down: Bool) {
        let tv = textView, string = tv.string as NSString, sels = tv.cursors
        let blocks = Self.lineBlocks(sels, in: string)
        let copies = blocks.map { block -> String in
            let text = string.substring(with: block)
            return (text as NSString).hasSuffix("\n") ? text : down ? tv.lineBreak + text : text + tv.lineBreak
        }
        tv.replace(blocks.map { NSRange(location: down ? NSMaxRange($0) : $0.location, length: 0) }, with: copies)
        let lengths = copies.map { ($0 as NSString).length }
        tv.setCursors(
            sels.map { selection in
                let index = blocks.lastIndex { $0.location <= selection.location } ?? 0
                return NSRange(
                    location: selection.location + lengths[..<index].reduce(0, +) + (down ? lengths[index] : 0),
                    length: selection.length)
            })
    }

    /// ⌘/: the touched lines commented out, or back in when they all are: with the language's line comment, else each
    /// line in its block comment (CSS, HTML).
    public func toggleComment() {
        let (open, close) =
            language.lineCommentString.isEmpty ? language.rangeCommentStrings : (language.lineCommentString, "")
        guard !open.isEmpty else { return NSSound.beep() }   // plain text
        let string = textView.string as NSString
        let lines = Typing.lines(textView.cursors, in: string).filter {
            Typing.leading(string, $0).length < $0.length - Typing.lineBreak(string, $0)
        }
        guard !lines.isEmpty else { return }
        let bodies = lines.map { line in NSRange(location: NSMaxRange(Typing.leading(string, line)), length: 0) }
            .enumerated().map { index, body in
                NSRange(
                    location: body.location,
                    length: NSMaxRange(lines[index]) - Typing.lineBreak(string, lines[index]) - body.location)   // after the indent
            }
        let texts = bodies.map { string.substring(with: $0) }
        if texts.allSatisfy({ $0.hasPrefix(open) && $0.hasSuffix(close) }) {
            var edits: [(NSRange, String)] = []
            for (body, text) in zip(bodies, texts) {
                let openLength = (open as NSString).length + (text.hasPrefix(open + " ") ? 1 : 0)
                edits.append((NSRange(location: body.location, length: openLength), ""))
                if !close.isEmpty {
                    let closeLength =
                        (close as NSString).length
                        + (text.hasSuffix(" " + close) && text.count > open.count + close.count ? 1 : 0)
                    edits.append((NSRange(location: NSMaxRange(body) - closeLength, length: closeLength), ""))
                }
            }
            return textView.replace(edits.map(\.0), with: edits.map(\.1), keep: true)
        }
        // At the block's least indent, so the marks line up.
        let column = zip(lines, bodies).map { $1.location - $0.location }.min() ?? 0
        var edits: [(NSRange, String)] = []
        for (line, body) in zip(lines, bodies) {
            edits.append((NSRange(location: line.location + column, length: 0), open + " "))
            if !close.isEmpty { edits.append((NSRange(location: NSMaxRange(body), length: 0), " " + close)) }
        }
        textView.replace(edits.map(\.0), with: edits.map(\.1), keep: true)
    }

    /// ⌘] / ⌘[: the touched lines a level in or out.
    public func indent(out: Bool) { Typing.shift(textView, out: out) }

    // MARK: Text

    /// The identifier around `location` (letters, digits, `_`, `$`); empty when there is none.
    static func word(at location: Int, in string: NSString) -> NSRange {
        let ident = CharacterSet.alphanumerics.union(.init(charactersIn: "_$"))
        func isIdent(_ index: Int) -> Bool {
            index >= 0 && index < string.length
                && UnicodeScalar(string.character(at: index)).map(ident.contains) == true
        }
        var start = location, end = location
        while isIdent(start - 1) { start -= 1 }
        while isIdent(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Where `needle` is, case and all; with `wholeWords`, not where it's part of a longer word (`id` in `width`).
    static func occurrences(of needle: String, in string: NSString, wholeWords: Bool = false) -> [NSRange] {
        var out: [NSRange] = [], from = 0
        while from < string.length {
            let found = string.range(
                of: needle, options: .literal, range: NSRange(location: from, length: string.length - from))
            guard found.location != NSNotFound, found.length > 0 else { break }
            if !wholeWords || isWord(found, in: string) { out.append(found) }
            from = NSMaxRange(found)
        }
        return out
    }

    /// A whole word: `range` is the identifier around its start (⌘D from a caret picks one, and then looks for words alone).
    static func isWord(_ range: NSRange, in string: NSString) -> Bool {
        range.length > 0 && word(at: range.location, in: string) == range
    }

    /// Whole lines under the selections, overlapping ones merged, top to bottom. A selection that ends at the start of
    /// a line (a triple-click) doesn't take that line.
    static func lineBlocks(_ sels: [NSRange], in string: NSString) -> [NSRange] {
        let lines = sels.sorted { $0.location < $1.location }.map { selection in
            string.lineRange(
                for: selection.length > 0 && string.character(at: NSMaxRange(selection) - 1) == 10
                    ? NSRange(location: selection.location, length: selection.length - 1) : selection)
        }
        return lines.reduce(into: []) { out, line in
            if let previous = out.last, line.location <= NSMaxRange(previous) {
                out[out.count - 1] = NSUnionRange(previous, line)
            } else {
                out.append(line)
            }
        }
    }
}

/// Selecting by what the code is, and more cursors.
extension CodeEditor {
    /// ⌃⇧⌘→: the next syntax node around the selection; with no grammar, the word, the line, then everything.
    public func expandSelection() {
        let tv = textView, string = tv.string as NSString, now = tv.selectedRange()
        guard let next = wider(than: now, in: string), next != now else { return }
        if now != selectionGrown { selectionSteps = [] }   // moved by hand since: those steps led somewhere else
        selectionSteps.append(now)
        selectionGrown = next
        tv.setSelectedRange(next)
    }

    /// ⌃⇧⌘←: back the way it grew.
    public func shrinkSelection() {
        guard textView.selectedRange() == selectionGrown, let last = selectionSteps.popLast() else { return }
        selectionGrown = last
        textView.setSelectedRange(last)
    }

    private func wider(than range: NSRange, in string: NSString) -> NSRange? {
        if let root = highlighter?.tree?.rootNode,
            var node = root.descendant(in: UInt32(range.location * 2)..<UInt32(NSMaxRange(range) * 2))
        {
            while node.range.length <= range.length || NSIntersectionRange(node.range, range) != range,
                let up = node.parent
            { node = up }
            if node.range.length > range.length { return node.range }
        }
        let word = range.length == 0 ? Self.word(at: range.location, in: string) : range
        if word != range, word.length > 0 { return word }
        let line = string.lineRange(for: range)
        return line != range ? line : NSRange(location: 0, length: string.length)
    }

    /// One more cursor on the line above or below each, at the same column.
    public func addCursor(above: Bool) {
        let tv = textView, string = tv.string as NSString
        tv.setCursors(
            tv.cursors
                + tv.cursors.map { NSRange(location: MultiCursor.vertical(string, $0.location, up: above), length: 0) })
    }

    /// ⌥⇧I: a cursor at the end of every line of the selection.
    public func cursorsAtLineEnds() {
        let tv = textView, string = tv.string as NSString, selection = tv.selectedRange()
        var ends: [NSRange] = [], at = selection.location
        repeat {
            let end = MultiCursor.lineEnd(string, at)
            ends.append(NSRange(location: end, length: 0))
            at = NSMaxRange(string.lineRange(for: NSRange(location: at, length: 0)))
        } while at < NSMaxRange(selection)
        tv.setCursors(ends)
    }
}
