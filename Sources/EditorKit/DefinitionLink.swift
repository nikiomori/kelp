import AppKit

/// ⌘ held over a word, in a file with a language server, makes the word a link to its definition (Xcode, VS Code): it
/// is underlined in the link colour, the pointer is a pointing hand, and a click opens the definition (⌥⌘: beside).
/// The underline is a temporary attribute, so the text doesn't change.
@MainActor
final class DefinitionLink {
    /// Opens the definition of the symbol at the cursor, beside when true. Nil when the file has no language server:
    /// then nothing is a link and a ⌘-click is a plain click.
    var onJump: ((_ beside: Bool) -> Void)?
    /// The word underlined now.
    private(set) var word: NSRange?
    /// What the words are (`CodeEditor` sets it), so keywords, literals, comments and strings don't look like links.
    weak var highlighter: SyntaxHighlighter?
    /// Highlights whose words open nothing: a keyword, a literal, a comment, a string.
    private static let notNames: Set<String> = [
        "keyword", "include", "boolean", "repeat", "conditional", "exception", "label", "variable.builtin",
        "constant.builtin", "comment", "string", "character", "escape", "number", "float", "punctuation", "operator"
    ]

    /// What a click with `flags` held does on a word: nil for a click like any other, else whether the definition
    /// opens beside (⌥⌘) or in place (⌘).
    static func beside(_ flags: NSEvent.ModifierFlags) -> Bool? {
        switch flags.intersection([.command, .option, .shift, .control]) {
        case .command: false
        case [.command, .option]: true
        default: nil
        }
    }

    /// The same click with ⌘ and ⌥ let go, for a ⌘-click on nothing to jump to.
    static func plain(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(
            with: event.type, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting([.command, .option]), timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
            clickCount: event.clickCount, pressure: event.pressure) ?? event
    }

    /// Underlines the word at `point` (the view's coordinates) while `flags` make it a link, and takes the underline
    /// off when they don't, or the pointer left the word (nil: left the view).
    func update(_ view: EditorTextView, at point: NSPoint?, _ flags: NSEvent.ModifierFlags) {
        let found = Self.beside(flags) == nil ? nil : point.flatMap { character(in: view, at: $0) }
        let range = found.map { CodeEditor.word(at: $0, in: view.string as NSString) }
        if range != nil { NSCursor.pointingHand.set() }   // each move, as the text view sets its I-beam again
        guard range != word else { return }
        if word != nil, range == nil, let point, view.visibleRect.contains(point) { NSCursor.iBeam.set() }
        mark(view, range)
    }

    /// A ⌘-click (⌥⌘: beside) on a link: the cursor goes to the character clicked and its definition opens. Returns
    /// false when there's nothing to jump to there.
    func open(_ view: EditorTextView, at point: NSPoint, _ event: NSEvent) -> Bool {
        guard event.clickCount == 1, let beside = Self.beside(event.modifierFlags), let onJump,
            let index = character(in: view, at: point)
        else { return false }
        view.window?.makeFirstResponder(view)
        view.setCursors([NSRange(location: index, length: 0)])
        mark(view, nil)
        onJump(beside)
        return true
    }

    /// The character under `point` when it's part of a name a language server could resolve: not a number, and not a
    /// keyword, a comment or a string (punctuation is no word).
    private func character(in view: EditorTextView, at point: NSPoint) -> Int? {
        guard onJump != nil, view.visibleRect.contains(point), let lm = view.layoutManager,
            let tc = view.textContainer
        else { return nil }
        let inside = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: inside, in: tc)
        guard glyph < lm.numberOfGlyphs,
            lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(inside)
        else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph), string = view.string as NSString
        let word = CodeEditor.word(at: index, in: string)
        guard NSLocationInRange(index, word),
            UnicodeScalar(string.character(at: word.location)).map(CharacterSet.decimalDigits.contains) == false
        else { return nil }
        if let name = highlighter?.highlight(at: index, in: string),
            Self.notNames.contains(name) || Self.notNames.contains(String(name.prefix { $0 != "." }))
        {
            return nil
        }
        return index
    }

    private func mark(_ view: EditorTextView, _ range: NSRange?) {
        guard let lm = view.layoutManager else { return }
        if let word, NSMaxRange(word) <= view.length {
            for key in [NSAttributedString.Key.underlineStyle, .underlineColor] {
                lm.removeTemporaryAttribute(key, forCharacterRange: word)
            }
        }
        word = range
        guard let range else { return }
        lm.addTemporaryAttributes(
            [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.linkColor],
            forCharacterRange: range)
    }
}

extension EditorTextView {
    /// ⌘ pressed or let go with the pointer still: the word under it becomes a link, or stops being one.
    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        link.update(self, at: convert(window.mouseLocationOutsideOfEventStream, from: nil), event.modifierFlags)
    }

    /// Focus gone elsewhere: a word linked while ⌘ was down stops being one.
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { link.update(self, at: nil, []) }
        return resigned
    }

    /// ⌘ let go in another window or app (after ⌘-Tab) never reaches this view, so the link also goes as its window
    /// stops being key.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default, resigned = NSWindow.didResignKeyNotification
        center.removeObserver(self, name: resigned, object: window)
        if let newWindow {
            center.addObserver(self, selector: #selector(windowResignedKey), name: resigned, object: newWindow)
        }
    }

    @objc private func windowResignedKey() { link.update(self, at: nil, []) }
}

extension CodeEditor {
    /// Opens the definition of the symbol at the cursor, beside when true. The tab sets it once the file has a language
    /// server; ⌘-click on a word (⌥⌘-click: beside) then puts the cursor there and calls it.
    public var onDefinition: ((_ beside: Bool) -> Void)? {
        get { textView.link.onJump }
        set {
            textView.link.onJump = newValue
            textView.link.highlighter = highlighter
        }
    }
}
