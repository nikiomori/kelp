import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView
import SwiftUI

/// The app talks to the editor only through this type (tree-sitter highlighting, find/replace,
/// multi-cursor and folding come from CodeEditSourceEditor).
@MainActor
public final class CodeEditor: NSObject {
    public static let readOnlyLimit = 5 * 1024 * 1024
    public let controller: TextViewController
    public var onChange: ((String) -> Void)?
    public var onSelection: (() -> Void)?
    private var suppress = false
    /// The controller holds coordinators weakly: without this reference the relay is gone at once and no edit is reported.
    private let relay = Relay()
    /// Big files (past this many lines) get their text after the view is set up, and no minimap (a second layout of it).
    private static let bigLines = 5_000
    private let big: Bool
    /// ⌥-click for another cursor (CodeEditor+Edits); nonisolated so deinit can remove it.
    nonisolated(unsafe) private var monitor: Any?
    /// The editors there are, to find the focused one (CodeEditor+Edits).
    static let all = NSHashTable<CodeEditor>.weakObjects()

    /// Big documents re-parse off the main thread so typing never waits for tree-sitter (highlighting catches up a frame later).
    private static let tuned: Void = { TreeSitterClient.Constants.maxSyncContentLength = 100_000 }()

    public init(text: String, url: URL, editable: Bool = true) {
        _ = Self.tuned
        let lang = CodeLanguage.detectLanguageFrom(url: url, prefixBuffer: String(text.prefix(200)))
        big = text.utf8.lazy.filter { $0 == 10 }.dropFirst(Self.bigLines).first != nil   // stops at the line past the limit
        let cfg = SourceEditorConfiguration(
            appearance: .init(theme: Self.theme, font: Self.font, wrapLines: Self.wrapLines),
            behavior: .init(isEditable: editable),
            peripherals: .init(showMinimap: Self.showMinimap && !big)
        )
        // A big file: empty first, the text once the view sits in its scroll view. A text view outside one lays out
        // every line (a 50k-line file was 24 s of main thread); inside, only what's on screen. (The minimap would keep
        // the first, empty text, hence none for these.)
        controller = TextViewController(string: big ? "" : text, language: lang, configuration: cfg,
                                        cursorPositions: [CursorPosition(line: 1, column: 1)], coordinators: [relay])
        super.init()
        relay.owner = self
        if big { _ = controller.view; suppress = true; controller.setText(text); suppress = false }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in self?.optionClick(e) ?? e }
        Self.all.add(self)
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    public var view: NSView { let v = controller.view; evenFoldRibbon(); return v }
    public var text: String { controller.text }

    /// Replace contents (e.g. the file changed on disk) without echoing a change event.
    public func setText(_ s: String) {
        // Unit for unit, not `==`: that compares the text view's NSString character by character (170 ms for 5 MB).
        let now = controller.text
        guard now.utf16.count != s.utf16.count || !(now as NSString).isEqual(to: s) else { return }
        let cursors = controller.cursorPositions
        suppress = true; controller.setText(s); suppress = false
        controller.setCursorPositions(cursors.map { CursorPosition(line: $0.start.line, column: $0.start.column) })
    }

    public var selectedText: String? {
        guard let tv = controller.textView else { return nil }
        let parts = tv.selectionManager.textSelections.map(\.range).filter { $0.length > 0 }
            .compactMap { tv.textStorage.attributedSubstring(from: $0).string as String? }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    public var selectedLines: ClosedRange<Int>? {
        guard let c = controller.cursorPositions.first else { return nil }
        return c.start.line...(c.end?.line ?? c.start.line)
    }

    /// 1-based line/column of the primary cursor.
    public var cursor: (line: Int, column: Int)? { controller.cursorPositions.first.map { ($0.start.line, $0.start.column) } }

    /// Completion items come from the app (LSP); the editor shows its native suggestion window.
    public var completionProvider: ((Int, Int) async -> [Completion])? {
        didSet { completer.owner = self; controller.completionDelegate = completionProvider == nil ? nil : completer }
    }
    private let completer = Completer()

    public struct Completion: CodeSuggestionEntry {
        public var label: String
        public var detail: String?
        public var insert: String
        public var documentation: String? { nil }
        public var pathComponents: [String]? { nil }
        public var targetPosition: CursorPosition? { nil }
        public var sourcePreview: String? { nil }
        public var image: Image { Image(systemName: "chevron.left.forwardslash.chevron.right") }
        public var imageColor: Color { .secondary }
        public var deprecated: Bool { false }
        public init(label: String, detail: String?, insert: String) { self.label = label; self.detail = detail; self.insert = insert }
    }

    /// Replace the identifier left of the cursor with `text`.
    fileprivate func applyCompletion(_ text: String) {
        guard let tv = controller.textView, let c = controller.cursorPositions.first else { return }
        let start = Self.word(at: c.range.location, in: tv.string as NSString).location
        tv.replaceCharacters(in: NSRange(location: start, length: c.range.location - start), with: text)
    }

    /// Primary selection in UTF-16 units.
    public var selectedRange: NSRange { controller.textView?.selectionManager.textSelections.first?.range ?? NSRange(location: 0, length: 0) }

    /// Replace everything as one undoable edit and set the selection (formatting toolbar).
    public func apply(text: String, selection: NSRange) {
        guard let tv = controller.textView else { return }
        tv.replaceCharacters(in: NSRange(location: 0, length: (tv.string as NSString).length), with: text)
        tv.selectionManager.setSelectedRanges([selection])
    }

    public func goTo(line: Int) { controller.setCursorPositions([CursorPosition(line: max(1, line), column: 1)], scrollToVisible: true) }
    public func focus() { controller.view.window?.makeFirstResponder(controller.textView) }

    fileprivate func changed() { if !suppress { onChange?(controller.text) } }

    /// Colors from the IDE theme (hex strings); nil keeps the Xcode-like defaults.
    public struct Palette: Equatable, Sendable {
        public var background, text: String
        public var keyword, string, comment, type, number, function, selection, lineHighlight: String?
        public init(background: String, text: String, keyword: String? = nil, string: String? = nil, comment: String? = nil, type: String? = nil,
                    number: String? = nil, function: String? = nil, selection: String? = nil, lineHighlight: String? = nil) {
            self.background = background; self.text = text; self.keyword = keyword; self.string = string; self.comment = comment
            self.type = type; self.number = number; self.function = function; self.selection = selection; self.lineHighlight = lineHighlight
        }
    }
    public static var palette: Palette?
    public static var fontSize: CGFloat = 13
    public static var fontName: String?
    /// Off by default: in a split next to an agent the minimap is a wide, mostly empty column.
    public static var showMinimap = false
    /// Off by default, as in most editors: a long line runs past the edge. On: it continues on the next row.
    public static var wrapLines = false

    /// Re-applies theme and font (after Settings change them).
    public func refreshAppearance() {
        var c = controller.configuration
        c.appearance.theme = Self.theme
        c.appearance.font = Self.font
        c.appearance.wrapLines = Self.wrapLines
        c.peripherals.showMinimap = Self.showMinimap && !big
        controller.configuration = c
        evenFoldRibbon()
    }

    /// CodeEdit's fold ribbon is twice as strong in dark mode as in light (white 20 % marks, a heavy grey bar beside the
    /// line numbers, against black 10 %), and its colours are internal: half its opacity in dark evens the two out.
    private func evenFoldRibbon() {
        func ribbon(in v: NSView) -> NSView? {
            NSStringFromClass(type(of: v)).hasSuffix("LineFoldRibbonView") ? v : v.subviews.lazy.compactMap(ribbon).first
        }
        let dark = (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua   // as defaultTheme decides
        ribbon(in: controller.view)?.alphaValue = dark ? 0.5 : 1
    }

    static var font: NSFont {
        Self.fontName.flatMap { NSFont(name: $0, size: Self.fontSize) } ?? .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
    }

    private static func hex(_ s: String?) -> NSColor? {
        guard var h = s?.trimmingCharacters(in: .whitespaces) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static var theme: EditorTheme {
        let base = defaultTheme
        guard let p = palette, let bg = hex(p.background), let fg = hex(p.text) else { return base }
        func a(_ s: String?, _ fallback: EditorTheme.Attribute, bold: Bool = false) -> EditorTheme.Attribute {
            hex(s).map { .init(color: $0, bold: bold) } ?? fallback
        }
        return EditorTheme(text: .init(color: fg), insertionPoint: fg, invisibles: base.invisibles, background: bg,
                           lineHighlight: hex(p.lineHighlight) ?? bg.blended(withFraction: 0.06, of: fg) ?? bg,
                           selection: hex(p.selection) ?? bg.blended(withFraction: 0.25, of: .controlAccentColor) ?? bg,
                           keywords: a(p.keyword, base.keywords, bold: true), commands: a(p.function, base.commands), types: a(p.type, base.types),
                           attributes: a(p.type, base.attributes), variables: .init(color: fg), values: a(p.number, base.values),
                           numbers: a(p.number, base.numbers), strings: a(p.string, base.strings), characters: a(p.string, base.characters),
                           comments: a(p.comment, base.comments))
    }

    /// The theme's token colors, for code drawn outside the editor (diffs), so both read alike.
    public static var tokenColors: (keyword: NSColor, string: NSColor, number: NSColor, comment: NSColor) {
        let t = theme
        return (t.keywords.color, t.strings.color, t.numbers.color, t.comments.color)
    }

    /// Xcode-like default themes; colors must be concrete RGB (the editor reads brightness components).
    static var defaultTheme: EditorTheme {
        let dark = (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        func a(_ hex: UInt32, bold: Bool = false) -> EditorTheme.Attribute { .init(color: c(hex), bold: bold) }
        if dark {
            return EditorTheme(text: a(0xDFDFE0), insertionPoint: c(0xFFFFFF), invisibles: a(0x53606E), background: c(0x1F1F24),
                               lineHighlight: c(0x23252B), selection: c(0x515B70), keywords: a(0xFF7AB2, bold: true), commands: a(0x67B7A4),
                               types: a(0x5DD8FF), attributes: a(0xCC9768), variables: a(0x41A1C0), values: a(0xA167E6),
                               numbers: a(0xD9C97C), strings: a(0xFF8170), characters: a(0xD9C97C), comments: a(0x7F8C98))
        }
        return EditorTheme(text: a(0x000000), insertionPoint: c(0x000000), invisibles: a(0xD6D6D6), background: c(0xFFFFFF),
                           lineHighlight: c(0xECF5FF), selection: c(0xB2D7FF), keywords: a(0x9B2393, bold: true), commands: a(0x326D74),
                           types: a(0x0B4F79), attributes: a(0x815F03), variables: a(0x0F68A0), values: a(0x6C36A9),
                           numbers: a(0x1C00CF), strings: a(0xC41A16), characters: a(0x1C00CF), comments: a(0x5D6C79))
    }
}

/// Receives CodeEditSourceEditor callbacks and forwards them to the owning editor.
private final class Relay: TextViewCoordinator {
    weak var owner: CodeEditor?
    func prepareCoordinator(controller: TextViewController) {}
    func textViewDidChangeText(controller: TextViewController) { MainActor.assumeIsolated { owner?.changed() } }
    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) { MainActor.assumeIsolated { owner?.onSelection?() } }
    func destroy() {}
}

private final class Completer: CodeSuggestionDelegate {
    weak var owner: CodeEditor?
    func completionTriggerCharacters() -> Set<String> { [".", ":"] }
    func completionSuggestionsRequested(textView: TextViewController,
                                        cursorPosition: CursorPosition) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let o = await MainActor.run(body: { owner }), let p = await MainActor.run(body: { o.completionProvider }) else { return nil }
        let items = await p(cursorPosition.start.line, cursorPosition.start.column)
        return items.isEmpty ? nil : (cursorPosition, items)
    }
    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? { nil }
    func completionWindowApplyCompletion(item: CodeSuggestionEntry, textView: TextViewController, cursorPosition: CursorPosition?) {
        guard let c = item as? CodeEditor.Completion else { return }
        MainActor.assumeIsolated { owner?.applyCompletion(c.insert) }
    }
}
