import AppKit
@preconcurrency import CodeEditLanguages

/// The app talks to the editor only through this type: an NSTextView (EditorTextView) with line numbers, tree-sitter
/// colors (SyntaxHighlighter), the find bar, more than one cursor and completion from the app's language server.
@MainActor
public final class CodeEditor: NSObject {
    public static let readOnlyLimit = 5 * 1024 * 1024
    /// More characters than this around the screen aren't colored. Only a file of very long lines has that many, and
    /// each token is a temporary attribute on the main thread (2.6 MB of JSON stopped the window 2.5 s per keystroke).
    static let colorSpan = 200_000
    /// A line longer than this makes each keystroke lay all of it out again in TextKit (200 KB: 230 ms; 2 MB: over a
    /// second per key), so such a file is shown, not edited.
    static let longestEditableLine = 100_000

    let textView = EditorTextView(usingTextLayoutManager: false)
    let scroll: NSScrollView = EditorScrollView()
    /// The font, colour and tab stops the text storage carries, so the same look again touches none of its 5 MB.
    var styled: NSDictionary?
    /// True when a look came while off screen (a hidden tab), so `apply(look:)` applies it when the editor shows.
    var lookPending = false
    /// Where the edits since the last coloring pass begin. An edit below the top line leaves the sticky scopes alone.
    private var editedFrom: Int?
    /// The top line the sticky scopes were found for (`refreshSticky`).
    var stickyTop: Int?
    public var view: NSView { scroll }
    public var onChange: ((String) -> Void)?
    /// The app's items for the editor's context menu, after Cut, Copy and Paste.
    public var contextMenu: ((NSMenu) -> Void)? {
        get { textView.contextMenu }
        set { textView.contextMenu = newValue }
    }
    public var onSelection: (() -> Void)?
    /// Completion items come from the app (LSP), and the text view shows them in its completion list.
    public var completionProvider: ((Int, Int) async -> [Completion])?
    /// This file's snippets, added to the language server's completions, or used alone when there is no server.
    public var snippetSource: (() async -> [Completion])?

    var lineIndex = LineIndex()
    var lineCount = 1
    /// What the language server says about the file. The tab sets it.
    public var problems: [Problem] = [] { didSet { if problems != oldValue { problemsChanged() } } }
    /// Lines with a problem, true where one of the problems is an error.
    var problemLines: [Int: Bool] = [:]
    /// The ⌘F bar, once it's been asked for.
    var findBar: FindBar?
    /// The completion list and a snippet's tab stops (CodeEditor+Completion changes them).
    var completion = CompletionState()
    /// What the server says of a 1-based position: a symbol's text, and the signature of the call there.
    public var hoverProvider: ((Int, Int) async -> String?)?
    public var signatureProvider: ((Int, Int) async -> (label: String, active: NSRange?)?)?
    /// Hover and signature cards, gray text, the next edit offered (CodeEditor+Hover, +Suggestion, +NextEdit).
    var hover = HoverState(), suggestion = SuggestionState(), nextEdit = NextEditState()
    /// The selection each Expand Selection grew from, for Shrink.
    var selectionSteps: [NSRange] = []
    /// The selection those steps led to.
    var selectionGrown: NSRange?
    /// The column lines wrap at, at the latest, when they wrap at all (`editor.wordWrapColumn`).
    public var wrapColumn: Int? {
        didSet { if wrapColumn != oldValue { refreshAppearance() } }
    }
    /// The columns where thin ruler lines are drawn.
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
    /// Whether the scopes around the top line stay pinned over the text (`editor.stickyScroll`).
    public var stickyEnabled = true {
        didSet { refreshSticky() }
    }
    /// How wide a tab shows, in columns.
    public private(set) var tabWidth = 4
    /// Sets this file's indentation, from its tab: what Tab and a new line put in, and the width of the tabs it has.
    public func useIndent(tabWidth: Int, spaces: Bool) {
        textView.guideColumns = tabWidth
        textView.indentUnit = spaces ? String(repeating: " ", count: tabWidth) : "\t"
        guard tabWidth != self.tabWidth else { return }
        self.tabWidth = tabWidth
        refreshAppearance()
    }
    /// This file's own say over `wrapLines`, from its language's settings.
    public var wrapsHere: Bool?
    /// Every `languageId`, named as in a settings.json "[language]" block ("markdown", "swift", "plaintext").
    public static var languageIds: [String] {
        (["plaintext"] + CodeLanguage.allLanguages.map(\.tsName)).filter { !$0.isEmpty }
    }
    public var languageId: String { language.id == .plainText ? "plaintext" : language.tsName }
    /// Whether the text is prose, which always wraps, whatever `wrapLines` says.
    public var alwaysWraps = false
    /// The change marks, top to bottom. The tab sets them, and typing moves them along.
    public var changeMarks: [ChangeMark] = [] {
        didSet {
            markedLineCount = lineCount
            gutter?.needsDisplay = true
            refreshScrollMarks()
        }
    }
    /// How many lines the file had when the marks were last right.
    var markedLineCount = 1
    /// Called for a click on a mark, with the mark and where it is in `in`.
    public var onChangeMark: ((_ mark: ChangeMark, _ at: NSRect, _ in: NSView) -> Void)?
    var bracketColor = NSColor.clear
    var gutter: LineNumbers?
    let highlighter: SyntaxHighlighter?
    let language: CodeLanguage
    /// The editor's own undo manager, so ⌘Z undoes this file's edits, not the last edit in whichever tab.
    private let undo = UndoManager()
    /// The latest edit, piece by piece, as the old text had it: where in its line each piece began, and what it took
    /// out and put in. Nil when the edit wasn't described (an undo's, or text set from disk).
    public private(set) var lastEdit: [(column: Int, removed: String, inserted: String)]?
    /// True while setting text that was on disk, so there is no change event and the line count is already known.
    private var loading = false
    private var described = false
    private var coloring = false
    /// The characters colored for this text, tree and theme.
    var colored: NSRange?
    /// Where the brackets are marked now.
    var marked: [NSRange] = []
    /// The editors there are, used to find the focused one (CodeEditor+Edits).
    static let all = NSHashTable<CodeEditor>.weakObjects()

    /// The editor showing the file at `url`, if one is.
    public static func showing(_ url: URL) -> CodeEditor? {
        all.allObjects.first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }
    public let url: URL

    public init(text: String, url: URL, editable: Bool = true) {
        self.url = url
        language = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(200)))
        // Past this size a file is only read, as tree-sitter's tree takes over 50 times the text (54 MB of JSON: 3 GB).
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
        (scroll as? EditorScrollView)?.onWindow = { [weak self] in
            guard let self, lookPending else { return }
            refreshAppearance()
        }
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
        // The menu's Find items reach `performFindPanelAction`; what they open is Kelp's own bar.
        tv.usesFindPanel = true
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
        tv.textContainer?.replaceLayoutManager(EditorLayoutManager())   // for the last, empty line's height
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.textStorage?.delegate = self
        tv.layoutManager?.delegate = tv   // for folds
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

    /// Sets the text without an undo step or a change event, to what was on disk, at first or after it changed there.
    private func load(_ contents: String) {
        _ = textView.folds.removeAll()   // the text is new, and its glyphs are made again anyway
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

    /// Replaces the contents (e.g. the file changed on disk) without echoing a change event.
    public func setText(_ contents: String) {
        let now = textView.string as NSString
        // Not `==`, because that compares character by character.
        guard now.length != contents.utf16.count || !now.isEqual(to: contents) else { return }
        let cursors = textView.cursors
        // Only what changed goes in, so an agent writing a file several times a second keeps the tree, folds and view.
        guard textView.isEditable else {   // read only, so `shouldChangeText` says no
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

    /// Replaces everything as one undoable edit and sets the selection (formatting toolbar). Only what differs is
    /// replaced, as by `setText`, though it is one undo step all the same. The whole text going in again dropped the
    /// folds, the change marks' places and the syntax tree, and parsed a 5 MB file anew for a trimmed space.
    public func apply(text: String, selection: NSRange) {
        let (old, fresh) = Self.changed(textView.string as NSString, text as NSString)
        textView.replace([old], with: [(text as NSString).substring(with: fresh)])
        textView.setSelectedRange(selection)
    }

    /// Moves the cursor to a line; `column` is 1-based, within the line.
    public func goTo(line: Int, column: Int = 1) {
        let string = textView.string as NSString
        var location = lineIndex.start(ofLine: max(0, line - 1), in: string) ?? textView.length
        if column > 1, location < string.length {
            location = min(location + column - 1, MultiCursor.lineEnd(string, location))
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// Scrolls `line` (1-based) to the top of what's on screen; the cursor stays.
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

    /// Fills whole lines behind the text: each range's lines, the editor's width. An empty list fills none.
    public func tint(_ tints: [(range: NSRange, color: NSColor)]) {
        guard !tints.isEmpty || !textView.lineTints.isEmpty else { return }   // still none, so nothing to redraw
        textView.lineTints = tints
    }

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
            let edit = editedFrom
            editedFrom = nil
            if !stickyHolds(after: edit) { refreshSticky() }
        }
    }

    /// Colors what's on screen and a screen around it, unless that's colored already, because a query runs on the
    /// main thread and every step of a scroll or of a panel sliding in comes through here.
    func colorVisible() {
        guard let highlighter, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let screen = textView.visibleRect
        let shown = textView.characters(in: screen)
        if let colored, NSIntersectionRange(colored, shown).length == shown.length { return }
        let around = textView.characters(in: screen.insetBy(dx: 0, dy: -screen.height))
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
        suggestionTextChanged()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        if hover.signatureCard?.isShown == true { askSignature() }
        if completion.completing != nil { refreshCompletions() }
        suggestionSelectionChanged()
        refreshScrollMarks()
        if textView.indentGuides { textView.setNeedsDisplay(textView.visibleRect) }   // which guide is the cursor's
        gutter?.needsDisplay = true
        markBrackets()
        onSelection?()
    }

    /// Called before an edit, while the old text is there, so the tree and the line count hear what's replaced by
    /// what.
    func willReplace(_ ranges: [NSRange], with texts: [String]) {
        if let range = ranges.first, let text = texts.first { nextEditWillReplace(range, with: text) }
        let string = textView.string as NSString
        var pieces: [(column: Int, removed: String, inserted: String)] = []
        // Goes from the bottom, so each edit's offsets still hold for the next.
        for (range, replacement) in zip(ranges, texts).reversed() {
            highlighter?.willReplace(range, with: replacement, in: string, lines: &lineIndex)
            let removed = string.substring(with: range)
            lineCount += replacement.utf16.lazy.filter { $0 == 10 }.count - removed.utf16.lazy.filter { $0 == 10 }.count
            marked = marked.compactMap { Self.moved($0, by: range, to: (replacement as NSString).length) }
            let lineStart = lineIndex.start(ofLine: lineIndex.line(at: range.location, in: string), in: string) ?? 0
            pieces.append((range.location - lineStart, removed, replacement))
        }
        lastEdit = pieces
        described = true
    }

    public nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {   // edits from the text view and from load both arrive on the main thread
            lineIndex.invalidate(from: editedRange.location)
            (textView.textContainer as? WrappingContainer)?.edited()
            if !described && !loading { lineCount = LineIndex.breaks(in: textView.string as NSString) + 1 }
            if !described { lastEdit = nil }
            editedFrom = min(editedFrom ?? editedRange.location, editedRange.location)
            if !loading { shiftChangeMarks(from: editedRange.location) }
            highlighter?.parse(textView.string as NSString, described: described)
            // A described edit's parse on its way colors the text when it's in (`parsed`), and the old colors moved
            // with the edit.
            if !described || highlighter?.waiting != true { colored = nil }
            described = false
            gutter?.needsDisplay = true
            scrolled()   // after the edit is laid out, the gutter's width too (resizing it in here broke the layout)
        }
    }
}
