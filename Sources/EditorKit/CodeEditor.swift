import AppKit
@preconcurrency import CodeEditLanguages

/// The app talks to the editor only through this type: an NSTextView (EditorTextView) with line numbers, tree-sitter
/// colors (SyntaxHighlighter), the find bar, more than one cursor and completion from the app's language server.
@MainActor
public final class CodeEditor: NSObject {
    public static let readOnlyLimit = 5 * 1024 * 1024
    /// More characters than this around the screen aren't colored: only a file of very long lines has that many, each token
    /// a temporary attribute on the main thread (2.6 MB of JSON stopped the window 2.5 s, after every keystroke).
    static let colorSpan = 200_000
    /// A line longer than this makes each keystroke lay all of it out again, in TextKit itself (200 KB: 230 ms; 2 MB: over a
    /// second, for every key): such a file is shown, not edited.
    static let longestEditableLine = 100_000

    public let textView = EditorTextView(usingTextLayoutManager: false)
    let scroll: NSScrollView = EditorScrollView()
    public var view: NSView { scroll }
    public var onChange: ((String) -> Void)?
    /// The app's items for the editor's context menu, after Cut, Copy and Paste.
    public var contextMenu: ((NSMenu) -> Void)? {
        get { textView.contextMenu }
        set { textView.contextMenu = newValue }
    }
    public var onSelection: (() -> Void)?
    /// Completion items come from the app (LSP); the text view shows them in its completion list.
    public var completionProvider: ((Int, Int) async -> [Completion])?
    /// This file's snippets, joining the server's or standing in when there's none.
    public var snippetSource: (() async -> [Completion])?

    var lineIndex = LineIndex()
    var lineCount = 1
    /// What the language server says. Set by the tab.
    public var problems: [Problem] = [] { didSet { if problems != oldValue { problemsChanged() } } }
    /// Lines with a problem; true where one is an error.
    var problemLines: [Int: Bool] = [:]
    /// ⌘F's, once it's been asked for.
    var findBar: FindBar?
    /// The completion list and a snippet's tab stops (CodeEditor+Completion changes it).
    var completion = CompletionState()
    /// What the server says of a 1-based position: a symbol's text, and the signature of the call there.
    public var hoverProvider: ((Int, Int) async -> String?)?
    public var signatureProvider: ((Int, Int) async -> (label: String, active: NSRange?)?)?
    /// The hover and signature cards (CodeEditor+Hover changes it).
    var hover = HoverState()
    /// What each Expand Selection grew from, for Shrink.
    var selectionSteps: [NSRange] = []
    /// The selection they led to.
    var selectionGrown: NSRange?
    /// Wraps here at the latest, when it wraps at all (`editor.wordWrapColumn`).
    public var wrapColumn: Int? {
        didSet { if wrapColumn != oldValue { refreshAppearance() } }
    }
    /// Thin lines at these columns.
    public var rulers: [Int] {
        get { textView.rulerColumns }
        set { textView.rulerColumns = newValue }
    }
    public var whitespace: EditorTextView.WhitespaceMarks {
        get { textView.whitespaceMarks }
        set { textView.whitespaceMarks = newValue }
    }
    /// Brackets coloured by depth (`editor.bracketColors`).
    public var bracketColors = false {
        didSet { if bracketColors != oldValue { refreshAppearance() } }
    }
    public var indentGuides: Bool {
        get { textView.indentGuides }
        set { textView.indentGuides = newValue }
    }
    /// The scopes around the top line stay pinned over the text (`editor.stickyScroll`).
    public var stickyEnabled = true {
        didSet { refreshSticky() }
    }
    /// How wide a tab shows.
    public private(set) var tabWidth = 4
    /// This file's indentation, from its tab: what Tab and a new line put in, and the width of the tabs it has.
    public func useIndent(tabWidth: Int, spaces: Bool) {
        textView.guideColumns = tabWidth
        textView.indentUnit = spaces ? String(repeating: " ", count: tabWidth) : "\t"
        guard tabWidth != self.tabWidth else { return }
        self.tabWidth = tabWidth
        refreshAppearance()
    }
    /// This file's own say over `wrapLines`, its language's settings.
    public var wrapsHere: Bool?
    /// The language as settings.json names it: "markdown", "swift", "plaintext".
    /// Every `languageId` there is, for a setting's "[language]" block.
    public static var languageIds: [String] {
        (["plaintext"] + CodeLanguage.allLanguages.map(\.tsName)).filter { !$0.isEmpty }
    }
    public var languageId: String { language.id == .plainText ? "plaintext" : language.tsName }
    /// Prose, whatever `wrapLines` says.
    public var alwaysWraps = false
    /// Top to bottom. Set by the tab; typing moves them along.
    public var changeMarks: [ChangeMark] = [] {
        didSet {
            markedLineCount = lineCount
            gutter?.needsDisplay = true
            refreshScrollMarks()
        }
    }
    /// How many lines the file had when the marks were last right.
    var markedLineCount = 1
    /// A click on a mark: the mark, and where it is in `in`.
    public var onChangeMark: ((_ mark: ChangeMark, _ at: NSRect, _ in: NSView) -> Void)?
    var bracketColor = NSColor.clear
    var gutter: LineNumbers?
    let highlighter: SyntaxHighlighter?
    let language: CodeLanguage
    /// Its own: ⌘Z undoes this file's edits, not the last edit in whichever tab.
    private let undo = UndoManager()
    /// Setting text that was on disk: no change event, its line count already known.
    private var loading = false
    private var described = false
    private var coloring = false
    /// The characters colored for this text, tree and theme.
    var colored: NSRange?
    /// Where the brackets are marked now.
    var marked: [NSRange] = []
    /// The editors there are, to find the focused one (CodeEditor+Edits).
    static let all = NSHashTable<CodeEditor>.weakObjects()

    /// The editor showing the file at `url`, if one is.
    public static func showing(_ url: URL) -> CodeEditor? {
        all.allObjects.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }
    public let url: URL

    public init(text: String, url: URL, editable: Bool = true) {
        self.url = url
        language = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(200)))
        // Past it a file is only read, and tree-sitter's tree takes more than 50 times the text (54 MB of JSON: 3 GB).
        highlighter = text.utf8.count <= Self.readOnlyLimit ? SyntaxHighlighter(language) : nil
        super.init()
        Self.all.add(self)
        setUpTextView(editable: editable)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let lineNumbers = LineNumbers(self, in: scroll)
        gutter = lineNumbers
        scroll.verticalRulerView = lineNumbers
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: textView)
        highlighter?.parsed = { [weak self] in
            self?.colored = nil
            self?.colorVisible()
            self?.markBrackets()
        }
        refreshAppearance()
        load(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.lineBreak = text.prefix(64_000).contains("\r\n") ? "\r\n" : "\n"
        textView.colonOpensBlock = ["python", "yaml"].contains(language.tsName)
    }

    private func setUpTextView(editable: Bool) {
        let tv = textView
        tv.isEditable = editable
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindPanel = true   // the menu's Find items reach `performFindPanelAction`; what they open is Kelp's own bar
        tv.smartInsertDeleteEnabled = false
        for off in [
            \NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled,
            \.isAutomaticTextReplacementEnabled,
            \.isAutomaticSpellingCorrectionEnabled, \.isAutomaticLinkDetectionEnabled,
            \.isContinuousSpellCheckingEnabled,
            \.isGrammarCheckingEnabled, \.isAutomaticTextCompletionEnabled, \.displaysLinkToolTips
        ] { tv[keyPath: off] = false }
        tv.inlinePredictionType = .no
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }   // code, not prose
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.textStorage?.delegate = self
        tv.layoutManager?.delegate = tv   // folds
        if let old = tv.textContainer {
            let container = WrappingContainer(size: old.size)
            container.widthTracksTextView = old.widthTracksTextView
            container.heightTracksTextView = old.heightTracksTextView
            container.lineFragmentPadding = old.lineFragmentPadding
            tv.replaceTextContainer(container)
        }
        tv.delegate = self
        tv.willReplace = { [weak self] in self?.willReplace($0, with: $1) }
        tv.onFind = { [weak self] in self?.find($0) }
        tv.onComplete = { [weak self] in self?.showCompletions() }
        (scroll as? EditorScrollView)?.sticky.onLine = { [weak self] in self?.goTo(line: $0 + 1) }
        tv.onTyped = { [weak self] in self?.typed($0) }
        tv.onCommand = { [weak self] in self?.handle($0) ?? false }
        tv.onPointer = { [weak self] in self?.pointerMoved($0) }
    }

    /// The text, without an undo step or a change event: what was on disk, at first or after it changed there.
    private func load(_ contents: String) {
        _ = textView.folds.removeAll()   // the text is new: its glyphs are made again anyway
        lineCount = Self.breaks(in: contents) + 1
        loading = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: contents, attributes: textView.typingAttributes))
        loading = false
        marked = []
        undo.removeAllActions()
        gutter?.fit(lines: lineCount)
    }

    public var text: String { textView.string }
    public var isMarkdown: Bool { language.id == .markdown }

    /// Replace contents (e.g. the file changed on disk) without echoing a change event.
    public func setText(_ contents: String) {
        let now = textView.string as NSString
        // Not `==`: that compares character by character.
        guard now.length != contents.utf16.count || !now.isEqual(to: contents) else { return }
        let cursors = textView.cursors
        // Only what changed goes in: an agent writing a file several times a second keeps the tree, the folds and the view.
        guard textView.isEditable else {   // read only: `shouldChangeText` says no
            load(contents)
            return textView.setCursors(cursors.map { NSRange(location: min($0.location, textView.length), length: 0) })
        }
        let (old, fresh) = Self.changed(now, contents as NSString)
        let inserted = (contents as NSString).substring(with: fresh)
        loading = true
        if textView.shouldChangeText(in: old, replacementString: inserted) {
            textView.textStorage?.replaceCharacters(
                in: old, with: NSAttributedString(string: inserted, attributes: textView.typingAttributes))
            textView.didChangeText()
        }
        loading = false
        undo.removeAllActions()
        gutter?.fit(lines: lineCount)
        textView.setCursors(
            cursors.map { cursor in
                NSRange(
                    location: cursor.location >= NSMaxRange(old)
                        ? cursor.location + fresh.length - old.length : min(cursor.location, NSMaxRange(fresh)),
                    length: 0)
            })
    }

    /// Replace everything as one undoable edit and set the selection (formatting toolbar).
    /// Only what differs is replaced, as by `setText` (one undo step all the same): the whole text going in again dropped
    /// the folds, the change marks' places and the syntax tree, and parsed a 5 MB file anew for a trimmed space.
    public func apply(text: String, selection: NSRange) {
        let (old, fresh) = Self.changed(textView.string as NSString, text as NSString)
        textView.replace([old], with: [(text as NSString).substring(with: fresh)])
        textView.setSelectedRange(selection)
    }

    /// `column` 1-based, within the line.
    public func goTo(line: Int, column: Int = 1) {
        let string = textView.string as NSString
        var location = lineIndex.start(ofLine: max(0, line - 1), in: string) ?? textView.length
        if column > 1, location < string.length {
            location = min(location + column - 1, MultiCursor.lineEnd(string, location))
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// The 1-based line at the top of what's on screen.
    public var topLine: Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 1 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: textView.visibleRect.minY), in: tc)
        return lineIndex.line(at: lm.characterIndexForGlyph(at: glyph), in: textView.string as NSString) + 1
    }

    /// `line` (1-based) at the top of what's on screen; the cursor stays.
    public func scroll(toLine line: Int) {
        let string = textView.string as NSString
        guard let lm = textView.layoutManager, string.length > 0,
            let start = lineIndex.start(ofLine: max(0, line - 1), in: string), start < string.length
        else { return }
        let top = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil).minY
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    public func focus() { textView.window?.makeFirstResponder(textView) }

    // MARK: Colors

    @objc private func scrolled() {
        guard !coloring else { return }
        coloring = true
        DispatchQueue.main.async { [weak self] in   // once per run loop pass
            guard let self else { return }
            coloring = false
            gutter?.fit(lines: lineCount)
            colorVisible()
            showProblemTips()
            fitWrapColumn()
            refreshSticky()
        }
    }

    /// What's on screen and a screen around it, unless that's colored already: a query runs on the main thread, and every
    /// step of a scroll or of a panel sliding in comes through here.
    func colorVisible() {
        guard let highlighter, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let screen = textView.visibleRect
        func characters(in rect: NSRect) -> NSRange {
            lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil)
        }
        let shown = characters(in: screen)
        if let colored, NSIntersectionRange(colored, shown).length == shown.length { return }
        let around = characters(in: screen.insetBy(dx: 0, dy: -screen.height))
        guard around.length <= Self.colorSpan else { return }
        highlighter.color(around, in: textView)
        colored = around
    }
}

extension CodeEditor: NSTextViewDelegate, NSTextStorageDelegate {
    public func undoManager(for view: NSTextView) -> UndoManager? { undo }

    public func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        onChange?(textView.string)
        findBar?.textChanged()
        refreshCompletions()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        if hover.signatureCard?.isShown == true { askSignature() }
        if completion.completing != nil { refreshCompletions() }
        refreshScrollMarks()
        if textView.indentGuides { textView.setNeedsDisplay(textView.visibleRect) }   // which guide is the cursor's
        gutter?.needsDisplay = true
        markBrackets()
        onSelection?()
    }

    /// Before an edit, while the old text is there: the tree and the line count hear what's replaced by what.
    func willReplace(_ ranges: [NSRange], with texts: [String]) {
        let string = textView.string as NSString
        // From the bottom: each edit's offsets still hold for the next.
        for (range, replacement) in zip(ranges, texts).reversed() {
            highlighter?.willReplace(range, with: replacement, in: string, lines: &lineIndex)
            lineCount +=
                replacement.utf16.lazy.filter { $0 == 10 }.count
                - string.substring(with: range).utf16.lazy.filter { $0 == 10 }.count
            marked = marked.compactMap { Self.moved($0, by: range, to: (replacement as NSString).length) }
        }
        described = true
    }

    public nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {   // the text view's and load's edits, both on the main thread
            lineIndex.invalidate(from: editedRange.location)
            (textView.textContainer as? WrappingContainer)?.edited()
            if !described && !loading { lineCount = LineIndex.breaks(in: textView.string as NSString) + 1 }
            if !loading { shiftChangeMarks(from: editedRange.location) }
            highlighter?.parse(textView.string as NSString, described: described)
            described = false
            gutter?.needsDisplay = true
            colored = nil
            scrolled()   // after the edit is laid out: the gutter's width too (resizing it in here broke the layout)
        }
    }
}
