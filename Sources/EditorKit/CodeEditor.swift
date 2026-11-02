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

    /// Whether editing `text` keeps the window responsive.
    public static func canEdit(_ text: String) -> Bool {
        var s = text
        guard s.utf8.count <= readOnlyLimit else { return false }
        return s.withUTF8 { b in
            guard var p = b.baseAddress else { return true }
            let end = p + b.count
            while end - p > longestEditableLine {
                guard let hit = memchr(p, 10, longestEditableLine) else { return false }
                p = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) + 1
            }
            return true
        }
    }
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
    public var completionProvider: ((Int, Int) async -> [Completion])? {
        didSet { textView.onComplete = completionProvider == nil ? nil : { [weak self] in self?.showCompletions() } }
    }

    var lineIndex = LineIndex()
    var lineCount = 1
    /// What the language server says. Set by the tab.
    public var problems: [Problem] = [] { didSet { if problems != oldValue { problemsChanged() } } }
    /// Lines with a problem; true where one is an error.
    var problemLines: [Int: Bool] = [:]
    /// ⌘F's, once it's been asked for.
    var findBar: FindBar?
    /// While the list is open: where the word it completes starts, and all that was offered.
    var completing: (start: Int, items: [Completion])?
    var completionList: CompletionList?
    /// A snippet's tab stops still to come, the current one first.
    var snippetStops: [[NSRange]] = []
    /// What the server says of a 1-based position: a symbol's text, and the signature of the call there.
    public var hoverProvider: ((Int, Int) async -> String?)?
    public var signatureProvider: ((Int, Int) async -> (label: String, active: NSRange?)?)?
    var hoverWait: DispatchWorkItem?
    var hoverShownAt: Int?
    var hoverCard: NSPopover?
    var signatureCard: NSPopover?
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

    public init(text: String, url: URL, editable: Bool = true) {
        language = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(200)))
        // Past it a file is only read, and tree-sitter's tree takes more than 50 times the text (54 MB of JSON: 3 GB).
        highlighter = text.utf8.count <= Self.readOnlyLimit ? SyntaxHighlighter(language) : nil
        super.init()
        Self.all.add(self)
        setUpTextView(editable: editable)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let g = LineNumbers(self, in: scroll)
        gutter = g
        scroll.verticalRulerView = g
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification, object: textView)
        highlighter?.parsed = { [weak self] in self?.colored = nil; self?.colorVisible(); self?.markBrackets() }
        refreshAppearance()
        load(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.indentUnit = Self.indentUnit(of: text)
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
        for off in [\NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled, \.isAutomaticTextReplacementEnabled,
                    \.isAutomaticSpellingCorrectionEnabled, \.isAutomaticLinkDetectionEnabled, \.isContinuousSpellCheckingEnabled,
                    \.isGrammarCheckingEnabled, \.isAutomaticTextCompletionEnabled, \.displaysLinkToolTips] { tv[keyPath: off] = false }
        tv.inlinePredictionType = .no
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }   // code, not prose
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.textStorage?.delegate = self
        tv.layoutManager?.delegate = tv   // folds
        if let old = tv.textContainer {
            let c = WrappingContainer(size: old.size)
            c.widthTracksTextView = old.widthTracksTextView
            c.heightTracksTextView = old.heightTracksTextView
            c.lineFragmentPadding = old.lineFragmentPadding
            tv.replaceTextContainer(c)
        }
        tv.delegate = self
        tv.willReplace = { [weak self] in self?.willReplace($0, with: $1) }
        tv.onFind = { [weak self] in self?.find($0) }
        (scroll as? EditorScrollView)?.sticky.onLine = { [weak self] in self?.goTo(line: $0 + 1) }
        tv.onTyped = { [weak self] in self?.typed($0) }
        tv.onCommand = { [weak self] in self?.handle($0) ?? false }
        tv.onPointer = { [weak self] in self?.pointerMoved($0) }
    }

    /// The text, without an undo step or a change event: what was on disk, at first or after it changed there.
    private func load(_ s: String) {
        _ = textView.folds.removeAll()   // the text is new: its glyphs are made again anyway
        lineCount = Self.breaks(in: s) + 1
        loading = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: textView.typingAttributes))
        loading = false
        marked = []
        undo.removeAllActions()
        gutter?.fit(lines: lineCount)
    }

    /// Line breaks in `s`, by memchr over its UTF-8 (a Swift loop over 5 MB took 150 ms in a debug build).
    static func breaks(in s: String) -> Int {
        var s = s
        return s.withUTF8 { b in
            guard var p = b.baseAddress else { return 0 }
            let end = p + b.count
            var n = 0
            while let hit = memchr(p, 10, end - p) { n += 1; p = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) + 1 }
            return n
        }
    }

    public var text: String { textView.string }
    public var isMarkdown: Bool { language.id == .markdown }

    /// Replace contents (e.g. the file changed on disk) without echoing a change event.
    public func setText(_ s: String) {
        let now = textView.string as NSString
        guard now.length != s.utf16.count || !now.isEqual(to: s) else { return }   // not `==`: that compares character by character
        let cursors = textView.cursors
        // Only what changed goes in: an agent writing a file several times a second keeps the tree, the folds and the view.
        guard textView.isEditable else {   // read only: `shouldChangeText` says no
            load(s)
            return textView.setCursors(cursors.map { NSRange(location: min($0.location, textView.length), length: 0) })
        }
        let (old, fresh) = Self.changed(now, s as NSString)
        let t = (s as NSString).substring(with: fresh)
        loading = true
        if textView.shouldChangeText(in: old, replacementString: t) {
            textView.textStorage?.replaceCharacters(in: old, with: NSAttributedString(string: t, attributes: textView.typingAttributes))
            textView.didChangeText()
        }
        loading = false
        undo.removeAllActions()
        gutter?.fit(lines: lineCount)
        textView.setCursors(cursors.map { c in
            NSRange(location: c.location >= NSMaxRange(old) ? c.location + fresh.length - old.length : min(c.location, NSMaxRange(fresh)), length: 0)
        })
    }

    /// The middle two texts don't share: what's in `a`, what's in `b`. Never between a surrogate pair's halves.
    static func changed(_ a: NSString, _ b: NSString) -> (old: NSRange, new: NSRange) {
        var x = [unichar](repeating: 0, count: a.length), y = [unichar](repeating: 0, count: b.length)
        a.getCharacters(&x, range: NSRange(location: 0, length: a.length))
        b.getCharacters(&y, range: NSRange(location: 0, length: b.length))
        let n = min(x.count, y.count)
        var head = 0, tail = 0
        while head < n, x[head] == y[head] { head += 1 }
        while tail < n - head, x[x.count - 1 - tail] == y[y.count - 1 - tail] { tail += 1 }
        if head > 0, UTF16.isLeadSurrogate(x[head - 1]) { head -= 1 }
        if tail > 0, UTF16.isTrailSurrogate(x[x.count - tail]) { tail -= 1 }
        return (NSRange(location: head, length: x.count - head - tail), NSRange(location: head, length: y.count - head - tail))
    }

    public var selectedText: String? {
        let s = textView.string as NSString
        let parts = textView.cursors.filter { $0.length > 0 }.map { s.substring(with: $0) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 1-based lines of the first selection; a line selected with its line break (a triple-click) is that line alone.
    public var selectedLines: ClosedRange<Int>? {
        let r = textView.selectedRange(), s = textView.string as NSString
        let end = r.length > 0 && s.character(at: NSMaxRange(r) - 1) == 10 ? NSMaxRange(r) - 1 : NSMaxRange(r)
        return lineIndex.line(at: r.location, in: s) + 1...lineIndex.line(at: end, in: s) + 1
    }

    /// 1-based line/column of the primary cursor.
    public var cursor: (line: Int, column: Int)? {
        let i = textView.selectedRange().location, s = textView.string as NSString
        let line = lineIndex.line(at: i, in: s)
        return (line + 1, i - (lineIndex.start(ofLine: line, in: s) ?? 0) + 1)
    }

    /// Primary selection in UTF-16 units.
    public var selectedRange: NSRange { textView.selectedRange() }

    /// Where the one selection's first line is on screen, in `view`'s coordinates; nil with no selection, several, or
    /// one scrolled out of sight.
    public var selectionRect: NSRect? {
        let r = textView.selectedRange(), s = textView.string as NSString
        guard textView.cursors.count == 1, r.length > 0, let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        let line = NSIntersectionRange(r, s.lineRange(for: NSRange(location: r.location, length: 0)))
        let glyphs = lm.glyphRange(forCharacterRange: line.length > 0 ? line : r, actualCharacterRange: nil)
        let box = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let shown = textView.visibleRect.intersection(box)
        return shown.isEmpty ? nil : view.convert(shown, from: textView)
    }

    /// Replace everything as one undoable edit and set the selection (formatting toolbar).
    public func apply(text: String, selection: NSRange) {
        textView.replace([NSRange(location: 0, length: textView.length)], with: [text])
        textView.setSelectedRange(selection)
    }

    public func goTo(line: Int) {
        let i = lineIndex.start(ofLine: max(0, line - 1), in: textView.string as NSString) ?? textView.length
        textView.setSelectedRange(NSRange(location: i, length: 0))
        textView.scrollRangeToVisible(NSRange(location: i, length: 0))
    }

    /// The 1-based line at the top of what's on screen.
    public var topLine: Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 1 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: textView.visibleRect.minY), in: tc)
        return lineIndex.line(at: lm.characterIndexForGlyph(at: glyph), in: textView.string as NSString) + 1
    }

    /// `line` (1-based) at the top of what's on screen; the cursor stays.
    public func scroll(toLine line: Int) {
        let s = textView.string as NSString
        guard let lm = textView.layoutManager, s.length > 0, let start = lineIndex.start(ofLine: max(0, line - 1), in: s), start < s.length else { return }
        let y = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil).minY
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
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
        func characters(in rect: NSRect) -> NSRange { lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil) }
        let shown = characters(in: screen)
        if let colored, NSIntersectionRange(colored, shown).length == shown.length { return }
        let around = characters(in: screen.insetBy(dx: 0, dy: -screen.height))
        guard around.length <= Self.colorSpan else { return }
        highlighter.color(around, in: textView)
        colored = around
    }

    /// A tab when most indented lines start with one; two spaces when that's the smallest indent; else four.
    static func indentUnit(of text: String) -> String {
        var tabs = 0, spaces: [Int] = []
        for line in text.prefix(64_000).split(separator: "\n").prefix(500) {   // the start of a big file is enough
            if line.hasPrefix("\t") { tabs += 1 } else if line.hasPrefix(" ") { spaces.append(line.prefix { $0 == " " }.count) }
        }
        if tabs > spaces.count { return "\t" }
        return spaces.min() == 2 ? "  " : "    "
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
        if signatureCard?.isShown == true { askSignature() }
        if completing != nil { refreshCompletions() }
        refreshScrollMarks()
        if textView.indentGuides { textView.setNeedsDisplay(textView.visibleRect) }   // which guide is the cursor's
        gutter?.needsDisplay = true
        markBrackets()
        onSelection?()
    }

    /// Before an edit, while the old text is there: the tree and the line count hear what's replaced by what.
    func willReplace(_ ranges: [NSRange], with texts: [String]) {
        let s = textView.string as NSString
        for (r, t) in zip(ranges, texts).reversed() {   // from the bottom: each edit's offsets still hold for the next
            highlighter?.willReplace(r, with: t, in: s, lines: &lineIndex)
            lineCount += t.utf16.lazy.filter { $0 == 10 }.count - s.substring(with: r).utf16.lazy.filter { $0 == 10 }.count
            marked = marked.compactMap { Self.moved($0, by: r, to: (t as NSString).length) }
        }
        described = true
    }

    public nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {   // the text view's and load's edits, both on the main thread
            lineIndex.invalidate(from: editedRange.location)
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
