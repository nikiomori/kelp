import AppKit

/// The code editor's text view: NSTextView on TextKit 1 (horizontal scrolling, the find bar, input methods, VoiceOver
/// and spelling come with it), with the current line marked and more than one cursor.
public final class EditorTextView: NSTextView {
    var lineHighlight = NSColor.clear
    /// What Tab inserts and indenting adds: the file's own (a tab, or its spaces), else four spaces.
    var indentUnit = "    "
    /// Python and YAML: a line ending in `:` opens a block, the next one goes in a level.
    var colonOpensBlock = false
    /// What Return and the line commands put between lines: the file's own (\r\n in a Windows file).
    var lineBreak = "\n"
    /// Cursors NSTextView can't hold: it keeps one empty selection at most, so the other carets' places are here.
    private(set) var extraCarets: [Int] = []
    private var settingCursors = false
    /// Where each cursor's selection started while ⇧ extends them all (MultiCursor), so each knows which end moves.
    var anchors: [Int] = []
    /// What's folded away (Folding).
    nonisolated let folds = Folds()
    /// The folded block whose ⋯ is under the pointer: it brightens, and the pointer is an arrow there (it's a button).
    var hoveredFold: NSRange? {
        didSet {
            guard hoveredFold != oldValue else { return }
            for r in [oldValue, hoveredFold].compactMap({ $0 }) { setNeedsDisplay(capsule(for: r).insetBy(dx: -2, dy: -2)) }
        }
    }
    /// Told of every edit before it's made, while the old text is there (CodeEditor: the parse tree, the line count).
    var willReplace: (([NSRange], [String]) -> Void)?
    /// Asks the app for completion items; they come back later, to `showCompletions`.
    var onComplete: (() -> Void)?
    var completions: [CodeEditor.Completion] = []
    private var presenting = false

    public var length: Int { (string as NSString).length }

    // MARK: Cursors

    /// Every cursor and selection, top to bottom.
    public var cursors: [NSRange] {
        (selectedRanges.map(\.rangeValue) + extraCarets.map { NSRange(location: $0, length: 0) }).sorted { $0.location < $1.location }
    }

    /// Sets them all, kept inside the text; overlapping ones merge.
    public func setCursors(_ ranges: [NSRange]) {
        let n = length
        let all = Self.merged(ranges.map { r in
            let a = min(max(0, r.location), n)
            return NSRange(location: a, length: min(max(0, r.length), n - a))
        })
        let wide = all.filter { $0.length > 0 }
        anchors = []   // ⇧ moves set them again after this
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
        if !settingCursors { extraCarets = []; anchors = [] }   // a click or an arrow: one cursor again
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true   // the current line's mark and the carets move
        // A cursor or a found match inside a fold opens it.
        for r in ranges.map(\.rangeValue) {
            for i in [r.location, NSMaxRange(r)] { if let f = folds.fold(at: i), i != f.location { setFolded(f, false) } }
        }
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
        scrollRangeToVisible(selectedRange())   // a Return on the last line shown brings the new line in
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
        if let strings {
            willReplace?(ranges.map(\.rangeValue), strings)
            // An edit into a fold opens it; the others move along. Laid out again once the edit is in.
            let edits = zip(ranges.map(\.rangeValue), strings.map { ($0 as NSString).length }).sorted { $0.0.location < $1.0.location }
            let opened = folds.isEmpty ? [] : folds.edit(edits)
            if !opened.isEmpty { DispatchQueue.main.async { [weak self] in opened.forEach { self?.relayOut($0) } } }
        }
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

    /// With several cursors: a line each when the clipboard has as many lines as there are cursors, else all of it at each.
    public override func paste(_ sender: Any?) {
        let cs = cursors
        guard cs.count > 1, let text = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        replace(cs, with: lines.count == cs.count ? lines : Array(repeating: text, count: cs.count))
    }

    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): Typing.newline(self)
        case #selector(insertTab(_:)): Typing.tab(self, back: false)
        case #selector(insertBacktab(_:)): Typing.tab(self, back: true)
        case #selector(deleteBackward(_:)) where cursors.count > 1: deleteAround { MultiCursor.before($0, in: $1) }
        case #selector(deleteForward(_:)) where cursors.count > 1: deleteAround { MultiCursor.after($0, in: $1) }
        case #selector(deleteWordBackward(_:)) where cursors.count > 1: deleteAround { MultiCursor.wordLeft($0, in: $1) }
        case #selector(deleteWordForward(_:)) where cursors.count > 1: deleteAround { MultiCursor.wordRight($0, in: $1) }
        case #selector(deleteToBeginningOfLine(_:)) where cursors.count > 1:
            deleteAround { i, s in s.lineRange(for: NSRange(location: i, length: 0)).location }
        case #selector(deleteBackward(_:)) where Typing.unpair(self): break
        case _ where cursors.count > 1 && MultiCursor.move(self, selector): break
        default:
            if cursors.count > 1 { setCursors([cursors[0]]) }
            super.doCommand(by: selector)
        }
    }

    /// ⌫ ⌦ ⌥⌫ ⌘⌫ at every cursor: its selection, or from the cursor to where `to` says.
    private func deleteAround(to: (Int, NSString) -> Int) {
        let s = string as NSString
        let ranges = cursors.compactMap { r -> NSRange? in
            if r.length > 0 { return r }
            let j = to(r.location, s)
            return j == r.location ? nil : NSRange(location: min(j, r.location), length: abs(j - r.location))
        }
        guard !ranges.isEmpty else { return }
        let gone = Self.merged(ranges)
        replace(gone, with: gone.map { _ in "" })
    }

    // MARK: Completion

    /// The identifier left of the cursor: NSTextView's own word would take `obj.na` whole, and no label starts with that.
    public override var rangeForUserCompletion: NSRange {
        let i = selectedRange().location
        let start = CodeEditor.word(at: i, in: string as NSString).location
        return NSRange(location: min(start, i), length: i - min(start, i))
    }

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

    // MARK: Context menu

    /// The app's part of the context menu (Send to Agent, Copy Path and Line…), after Cut, Copy and Paste.
    var contextMenu: ((NSMenu) -> Void)?

    /// A code editor's menu, not a rich-text one: no fonts, writing direction or substitutions, and none of what the
    /// system adds to text views (Writing Tools, Siri, Services).
    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.allowsContextMenuPlugIns = false
        for (title, action, key) in [("Cut", #selector(cut(_:)), "x"), ("Copy", #selector(copy(_:)), "c"), ("Paste", #selector(paste(_:)), "v")] {
            m.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        if let contextMenu {
            m.addItem(.separator())
            contextMenu(m)
        }
        return m
    }

    // MARK: Mouse

    public override func mouseMoved(with e: NSEvent) {
        let at = convert(e.locationInWindow, from: nil)
        hoveredFold = folds.isEmpty ? nil : folds.hidden.first { capsule(for: $0).contains(at) }
        if hoveredFold != nil { NSCursor.arrow.set() } else { super.mouseMoved(with: e) }
    }
    public override func mouseExited(with e: NSEvent) { hoveredFold = nil; super.mouseExited(with: e) }

    /// ⌥-click (VS Code) or ⌃⇧-click (Xcode) adds a cursor; ⌥-drag still selects columns, NSTextView's own way.
    public override func mouseDown(with e: NSEvent) {
        let at = convert(e.locationInWindow, from: nil)
        if let f = folds.hidden.first(where: { capsule(for: $0).contains(at) }) { return setFolded(f, false) }   // a ⋯ opens
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
        drawCapsules(in: dirtyRect)
        guard !extraCarets.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        // Only the carets in what's drawn: ⇧⌘L on a common word in a big file makes thousands.
        let shown = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: dirtyRect.insetBy(dx: 0, dy: -20), in: tc), actualGlyphRange: nil)
        insertionPointColor.setFill()
        for i in extraCarets where i >= shown.location && i <= NSMaxRange(shown) { caretRect(at: i).intersection(dirtyRect).fill() }
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
