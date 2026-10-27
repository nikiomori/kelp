import AppKit
@preconcurrency import CodeEditLanguages

/// The app talks to the editor only through this type: an NSTextView (EditorTextView) with line numbers, tree-sitter
/// colors (SyntaxHighlighter), the find bar, more than one cursor and completion from the app's language server.
@MainActor
public final class CodeEditor: NSObject {
    public static let readOnlyLimit = 5 * 1024 * 1024
    public let textView = EditorTextView(usingTextLayoutManager: false)
    let scroll = NSScrollView()
    public var view: NSView { scroll }
    public var onChange: ((String) -> Void)?
    public var onSelection: (() -> Void)?
    /// Completion items come from the app (LSP); the text view shows them in its completion list.
    public var completionProvider: ((Int, Int) async -> [Completion])? {
        didSet { textView.onComplete = completionProvider == nil ? nil : { [weak self] in self?.complete() } }
    }

    var lineIndex = LineIndex()
    var lineCount = 1
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
    /// The editors there are, to find the focused one (CodeEditor+Edits).
    static let all = NSHashTable<CodeEditor>.weakObjects()

    public struct Completion: Sendable {
        public var label: String
        public var detail: String?
        public var insert: String
        public init(label: String, detail: String?, insert: String) { self.label = label; self.detail = detail; self.insert = insert }
    }

    public init(text: String, url: URL, editable: Bool = true) {
        language = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(200)))
        highlighter = SyntaxHighlighter(language)
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
        highlighter?.parsed = { [weak self] in self?.colorVisible(); self?.markBrackets() }
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
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.smartInsertDeleteEnabled = false
        for off in [\NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled, \.isAutomaticTextReplacementEnabled,
                    \.isAutomaticSpellingCorrectionEnabled, \.isAutomaticLinkDetectionEnabled, \.isContinuousSpellCheckingEnabled,
                    \.isGrammarCheckingEnabled, \.isAutomaticTextCompletionEnabled, \.displaysLinkToolTips] { tv[keyPath: off] = false }
        tv.inlinePredictionType = .no
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.textStorage?.delegate = self
        tv.layoutManager?.delegate = tv   // folds
        tv.delegate = self
        tv.willReplace = { [weak self] in self?.willReplace($0, with: $1) }
    }

    /// The text, without an undo step or a change event: what was on disk, at first or after it changed there.
    private func load(_ s: String) {
        _ = textView.folds.removeAll()   // the text is new: its glyphs are made again anyway
        lineCount = Self.breaks(in: s) + 1
        loading = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: textView.typingAttributes))
        loading = false
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
        load(s)
        textView.setCursors(cursors.map { NSRange(location: min($0.location, textView.length), length: 0) })
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
        }
    }

    /// What's on screen and a screen around it.
    func colorVisible() {
        guard let highlighter, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let rect = textView.visibleRect.insetBy(dx: 0, dy: -textView.visibleRect.height)
        let r = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil)
        highlighter.color(r, in: textView)
    }

    private func complete() {
        guard let provider = completionProvider, let (line, column) = cursor else { return }
        let at = textView.selectedRange()
        Task { [weak self] in
            let items = await provider(line, column)
            guard let self, textView.selectedRange() == at, !items.isEmpty else { return }
            textView.showCompletions(items)
        }
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

    public func textDidChange(_ notification: Notification) { if !loading { onChange?(textView.string) } }

    public func textViewDidChangeSelection(_ notification: Notification) {
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
        }
        described = true
    }

    public nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {   // the text view's and load's edits, both on the main thread
            lineIndex.invalidate(from: editedRange.location)
            if !described && !loading { lineCount = LineIndex.breaks(in: textView.string as NSString) + 1 }
            highlighter?.parse(textView.string as NSString, described: described)
            described = false
            gutter?.needsDisplay = true
            scrolled()   // after the edit is laid out: the gutter's width too (resizing it in here broke the layout)
        }
    }
}
