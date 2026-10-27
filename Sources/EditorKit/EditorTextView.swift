import AppKit

/// The code editor's text view: NSTextView on TextKit 1 (horizontal scrolling, the find bar, input methods, VoiceOver
/// and spelling come with it), with the current line marked and more than one cursor.
public final class EditorTextView: NSTextView {
    var lineHighlight = NSColor.clear
    /// What Tab inserts and indenting adds: the file's own (a tab, or its spaces), else four spaces.
    var indentUnit = "    "
    /// Python and YAML: a line ending in `:` opens a block, the next one goes in a level.
    var colonOpensBlock = false
    /// Cursors NSTextView can't hold: it keeps one empty selection at most, so the other carets' places are here.
    private(set) var extraCarets: [Int] = []
    private var settingCursors = false
    /// Told of every edit before it's made, while the old text is there (CodeEditor: the parse tree, the line count).
    var willReplace: (([NSRange], [String]) -> Void)?
    /// Asks the app for completion items; they come back later, to `showCompletions`.
    var onComplete: (() -> Void)?
    private var completions: [CodeEditor.Completion] = []
    private var presenting = false

    public var length: Int { (string as NSString).length }

    // MARK: Cursors

    /// Every cursor and selection, top to bottom.
    public var cursors: [NSRange] {
        (selectedRanges.map(\.rangeValue) + extraCarets.map { NSRange(location: $0, length: 0) }).sorted { $0.location < $1.location }
    }

    /// Sets them all; overlapping ones merge.
    public func setCursors(_ ranges: [NSRange]) {
        let all = Self.merged(ranges.filter { $0.location >= 0 && NSMaxRange($0) <= length })
        let wide = all.filter { $0.length > 0 }
        settingCursors = true
        if all.count <= 1 || wide.isEmpty {
            setSelectedRange(all.first ?? NSRange(location: min(selectedRange().location, length), length: 0))
            extraCarets = all.dropFirst().map(\.location)
        } else {
            selectedRanges = wide.map { NSValue(range: $0) }
            extraCarets = all.filter { $0.length == 0 }.map(\.location)
        }
        settingCursors = false
        needsDisplay = true
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !settingCursors { extraCarets = [] }   // a click or an arrow: one cursor again
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true   // the current line's mark and the carets move
    }

    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }.reduce(into: []) { out, r in
            guard let p = out.last, r.location < NSMaxRange(p) || r == p || (p.length == 0 && r.location == p.location) else { return out.append(r) }
            out[out.count - 1] = NSUnionRange(p, r)
        }
    }

    // MARK: Editing

    /// Each range (top to bottom, apart) replaced by its text as one undoable change. The cursors land after each new
    /// text, at `caret` within it, or (`keep`) stay where they were, moved along by the change.
    public func replace(_ ranges: [NSRange], with texts: [String], caret: [Int]? = nil, keep: Bool = false) {
        guard isEditable, !ranges.isEmpty, shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: texts) else { return }
        let before = cursors
        textStorage?.beginEditing()
        for (r, t) in zip(ranges, texts).reversed() { textStorage?.replaceCharacters(in: r, with: NSAttributedString(string: t, attributes: typingAttributes)) }
        textStorage?.endEditing()
        didChangeText()
        let edits = zip(ranges, texts).map { ($0, ($1 as NSString).length) }
        if keep {
            return setCursors(before.map { r in
                let a = Self.map(r.location, through: edits), b = Self.map(NSMaxRange(r), through: edits)
                return NSRange(location: a, length: max(0, b - a))
            })
        }
        var shift = 0
        setCursors(edits.enumerated().map { i, e in
            defer { shift += e.1 - e.0.length }
            return NSRange(location: e.0.location + shift + (caret?[i] ?? e.1), length: 0)
        })
    }

    /// Where offset `p` is after the edits (old range, new length; top to bottom): one in a replaced range goes to its start.
    static func map(_ p: Int, through edits: [(NSRange, Int)]) -> Int {
        var shift = 0
        for (r, n) in edits {
            if p <= r.location { break }
            if p < NSMaxRange(r) { return r.location + shift }
            shift += n - r.length
        }
        return p + shift
    }

    public override func shouldChangeText(inRanges ranges: [NSValue], replacementStrings strings: [String]?) -> Bool {
        guard super.shouldChangeText(inRanges: ranges, replacementStrings: strings) else { return false }
        if let strings { willReplace?(ranges.map(\.rangeValue), strings) }
        return true
    }

    public override func shouldChangeText(in range: NSRange, replacementString string: String?) -> Bool {
        shouldChangeText(inRanges: [NSValue(range: range)], replacementStrings: string.map { [$0] })
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        guard cursors.count > 1, replacementRange.location == NSNotFound, !hasMarkedText() else {
            if replacementRange.location == NSNotFound, !hasMarkedText(), Typing.pairs(self, s) { return }
            super.insertText(string, replacementRange: replacementRange)
            if s == "." { onComplete?() }
            return
        }
        let cs = cursors
        replace(cs, with: Array(repeating: s, count: cs.count))
    }

    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): Typing.newline(self)
        case #selector(insertTab(_:)): Typing.tab(self, back: false)
        case #selector(insertBacktab(_:)): Typing.tab(self, back: true)
        case #selector(deleteBackward(_:)) where cursors.count > 1: deleteAround(back: true)
        case #selector(deleteForward(_:)) where cursors.count > 1: deleteAround(back: false)
        case #selector(deleteBackward(_:)) where Typing.unpair(self): break
        case _ where cursors.count > 1 && MultiCursor.move(self, selector): break
        default:
            if cursors.count > 1 { setCursors([cursors[0]]) }
            super.doCommand(by: selector)
        }
    }

    /// ⌫ / ⌦ at every cursor: its selection, or the character before (after) it.
    private func deleteAround(back: Bool) {
        let s = string as NSString
        let ranges = cursors.compactMap { r -> NSRange? in
            if r.length > 0 { return r }
            if back { return r.location > 0 ? s.rangeOfComposedCharacterSequence(at: r.location - 1) : nil }
            return r.location < s.length ? s.rangeOfComposedCharacterSequence(at: r.location) : nil
        }
        guard !ranges.isEmpty else { return }
        let gone = Self.merged(ranges)
        replace(gone, with: gone.map { _ in "" })
    }

    // MARK: Completion

    /// Esc (NSTextView's key for it) asks the app; the list opens when its items come.
    public override func complete(_ sender: Any?) {
        if presenting { return super.complete(sender) }
        onComplete?()
    }

    func showCompletions(_ items: [CodeEditor.Completion]) {
        completions = items
        presenting = true
        super.complete(nil)
        presenting = false
    }

    public override func completions(forPartialWordRange r: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let typed = (string as NSString).substring(with: r).lowercased()
        let labels = completions.map(\.label).filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
        return labels.isEmpty ? nil : labels
    }

    /// The item's text goes in, which may differ from the label the list shows.
    public override func insertCompletion(_ word: String, forPartialWordRange r: NSRange, movement: Int, isFinal: Bool) {
        let item = isFinal ? completions.first { $0.label == word }?.insert : nil
        super.insertCompletion(item ?? word, forPartialWordRange: r, movement: movement, isFinal: isFinal)
    }

    // MARK: Mouse

    /// ⌥-click (VS Code) or ⌃⇧-click (Xcode) adds a cursor; ⌥-drag still selects columns, NSTextView's own way.
    public override func mouseDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .shift, .control])
        guard e.clickCount == 1, isEditable, mods == .option || mods == [.control, .shift] else { return super.mouseDown(with: e) }
        let before = cursors
        if mods == .option {
            super.mouseDown(with: e)   // tracks until the button is up
            guard selectedRanges.count == 1, selectedRange().length == 0 else { return }   // dragged: the columns stay
        }
        setCursors(before + [NSRange(location: characterIndexForInsertion(at: convert(e.locationInWindow, from: nil)), length: 0)])
    }

    // MARK: Drawing

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard cursors.count == 1, selectedRange().length == 0, lineHighlight.alphaComponent > 0 else { return }
        var line = caretRect(at: selectedRange().location)
        line.origin.x = 0
        line.size.width = bounds.width
        lineHighlight.setFill()
        line.intersection(rect).fill()
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !extraCarets.isEmpty else { return }
        insertionPointColor.setFill()
        for i in extraCarets { caretRect(at: i).intersection(dirtyRect).fill() }
    }

    /// Where a caret at `i` stands, in the view: one point wide, a line high.
    func caretRect(at i: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        var r: NSRect
        if i < length {
            let g = lm.glyphIndexForCharacter(at: i)
            r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            r.origin.x += lm.location(forGlyphAt: g).x
        } else if length == 0 || !lm.extraLineFragmentRect.isEmpty {   // after a final newline
            r = lm.extraLineFragmentRect
        } else {   // after the last character of a last line without one
            let g = lm.glyphIndexForCharacter(at: length - 1)
            r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            r.origin.x = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).maxX
        }
        r = r.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        r.size.width = 1
        return r
    }
}
