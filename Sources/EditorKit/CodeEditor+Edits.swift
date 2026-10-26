import AppKit
import CodeEditSourceEditor
import CodeEditTextView

/// VS Code's editing commands that CodeEditSourceEditor leaves out (it has ⌘/, ⌘[ ⌘], ⌃⇧-click for a cursor and
/// ⌥-drag for columns). Their keys are the Selection menu's, on only while an editor has the focus (`focused`): a key
/// monitor can't keep a key from the menu, and elsewhere ⌘D splits.
extension CodeEditor {
    /// The editor whose text view has the focus in the key window.
    public static var focused: CodeEditor? {
        all.allObjects.first { e in
            e.controller.textView.map { tv in tv.window?.firstResponder === tv && (NSApp.keyWindow ?? tv.window) === tv.window } == true
        }
    }

    /// ⌥-click adds a cursor (VS Code): from the editor's mouse monitor, the click goes on as the ⌃⇧-click the text
    /// view knows, so an ⌥-drag that follows still selects columns.
    func optionClick(_ e: NSEvent) -> NSEvent {
        guard e.modifierFlags.intersection([.command, .option, .shift, .control]) == .option, e.clickCount == 1,
              let tv = controller.textView, tv.isEditable, e.window === tv.window, let content = tv.window?.contentView,
              content.hitTest(content.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow)?.isDescendant(of: tv) == true,
              let click = NSEvent.mouseEvent(with: .leftMouseDown, location: e.locationInWindow, modifierFlags: [.control, .shift],
                                             timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                             eventNumber: e.eventNumber, clickCount: 1, pressure: e.pressure) else { return e }
        return click
    }

    /// ⌘D: the word at each cursor; then the next occurrence of the selected text joins the selections, past the
    /// last one and then from the top.
    public func addNextOccurrence() {
        guard let tv = controller.textView else { return }
        let s = tv.string as NSString
        let sels = tv.selectionManager.textSelections.map(\.range)
        if sels.contains(where: { $0.length == 0 }) {
            return tv.selectionManager.setSelectedRanges(sels.map { $0.length > 0 ? $0 : Self.word(at: $0.location, in: s) })
        }
        guard let last = sels.last else { return }
        let free = Self.occurrences(of: s.substring(with: last), in: s).filter { !sels.contains($0) }
        guard let next = free.first(where: { $0.location >= last.max }) ?? free.first else { return }
        tv.selectionManager.addSelectedRange(next)
        tv.scrollToRange(next, center: false)
    }

    /// ⇧⌘L: every occurrence of the selected text (or of the word at the cursor).
    public func selectAllOccurrences() {
        guard let tv = controller.textView, let first = tv.selectionManager.textSelections.first?.range else { return }
        let s = tv.string as NSString
        let r = first.length > 0 ? first : Self.word(at: first.location, in: s)
        guard r.length > 0 else { return }
        tv.selectionManager.setSelectedRanges(Self.occurrences(of: s.substring(with: r), in: s))
    }

    /// ⇧⌘K: the lines the selections touch, in one undo.
    public func deleteLines() {
        guard let tv = controller.textView else { return }
        let s = tv.string as NSString
        let blocks = Self.lineBlocks(tv.selectionManager.textSelections.map(\.range), in: s).map { b in
            // The last line has no newline of its own: take the one before it, or an empty line stays behind.
            b.max == s.length && b.location > 0 && s.character(at: b.max - 1) != 10 ? NSRange(location: b.location - 1, length: b.length + 1) : b
        }
        tv.undoManager?.beginUndoGrouping()
        tv.replaceCharacters(in: blocks, with: "")
        tv.undoManager?.endUndoGrouping()
    }

    /// ⌥↓ / ⌥↑: the selected lines trade places with the line below or above, selections along. (CodeEditSourceEditor's
    /// own moves a line once per cursor: two cursors on one line took it two lines down.)
    public func moveLines(down: Bool) {
        guard let tv = controller.textView else { return }
        let s = tv.string as NSString
        let sels = tv.selectionManager.textSelections.map(\.range)
        let blocks = Self.lineBlocks(sels, in: s)
        // Each block with its neighbour, as one replacement; blocks are a line apart at least, so the swaps don't meet.
        let swaps = blocks.map { b -> (range: NSRange, text: String, shift: Int)? in
            guard down ? b.max < s.length : b.location > 0 else { return nil }
            let other = s.lineRange(for: NSRange(location: down ? b.max : b.location - 1, length: 0))
            var (top, bottom) = down ? (s.substring(with: other), s.substring(with: b)) : (s.substring(with: b), s.substring(with: other))
            if !(top as NSString).hasSuffix("\n") {   // the last line moves up: its line break goes with the line now above it
                top += bottom.hasSuffix("\r\n") ? "\r\n" : "\n"; bottom.removeLast()
            }
            let moved = (down ? top : bottom) as NSString
            return (NSUnionRange(b, other), top + bottom, down ? moved.length : -(other.length))
        }
        tv.undoManager?.beginUndoGrouping()
        for swap in swaps.reversed() { if let swap { tv.replaceCharacters(in: swap.range, with: swap.text, skipUpdateSelection: true) } }
        tv.undoManager?.endUndoGrouping()
        tv.selectionManager.setSelectedRanges(sels.map { r in
            let i = blocks.lastIndex { $0.location <= r.location } ?? 0
            return NSRange(location: r.location + (swaps[i]?.shift ?? 0), length: r.length)
        })
        tv.scrollSelectionToVisible()
    }

    /// ⇧⌥↓ / ⇧⌥↑: the selected lines once more, below or above; the selections move to the copy below, or stay on the
    /// one above, as in VS Code.
    public func copyLines(down: Bool) {
        guard let tv = controller.textView else { return }
        let s = tv.string as NSString
        let sels = tv.selectionManager.textSelections.map(\.range)
        let blocks = Self.lineBlocks(sels, in: s)
        let copies = blocks.map { b -> String in
            let text = s.substring(with: b)
            return (text as NSString).hasSuffix("\n") ? text : down ? "\n" + text : text + "\n"
        }
        tv.undoManager?.beginUndoGrouping()
        for (b, text) in zip(blocks, copies).reversed() {   // from the bottom: the offsets above stay as they were
            tv.replaceCharacters(in: NSRange(location: down ? b.max : b.location, length: 0), with: text, skipUpdateSelection: true)
        }
        tv.undoManager?.endUndoGrouping()
        let lengths = copies.map { ($0 as NSString).length }
        tv.selectionManager.setSelectedRanges(sels.map { r in
            let i = blocks.lastIndex { $0.location <= r.location } ?? 0
            return NSRange(location: r.location + lengths[..<i].reduce(0, +) + (down ? lengths[i] : 0), length: r.length)
        })
    }

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
            out.append(r); from = r.max
        }
        return out
    }

    /// Whole lines under the selections, overlapping ones merged, top to bottom. A selection that ends at the start of
    /// a line (a triple-click) doesn't take that line.
    static func lineBlocks(_ sels: [NSRange], in s: NSString) -> [NSRange] {
        let lines = sels.sorted { $0.location < $1.location }.map { r in
            s.lineRange(for: r.length > 0 && s.character(at: r.max - 1) == 10 ? NSRange(location: r.location, length: r.length - 1) : r)
        }
        return lines.reduce(into: []) { out, l in
            if let p = out.last, l.location <= p.max { out[out.count - 1] = NSUnionRange(p, l) } else { out.append(l) }
        }
    }
}
