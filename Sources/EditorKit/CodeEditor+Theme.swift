import AppKit
import DesignKit

/// Colors, font and line wrapping, from the IDE theme and Settings › Editor.
extension CodeEditor {
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
    /// Off by default, as in most editors: a long line runs past the edge and scrolls. On: it continues on the next row.
    public static var wrapLines = false

    /// The colors in use: the palette's, else Xcode's defaults for the appearance.
    struct Look {
        var background, text, lineHighlight, selection: NSColor
        var keyword, string, comment, type, number, function: NSColor
    }

    static var look: Look {
        let dark = (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c = { (v: Int) in NSColor(hex: v) }
        let base = dark
            ? Look(background: c(0x1F1F24), text: c(0xDFDFE0), lineHighlight: c(0x23252B), selection: c(0x515B70), keyword: c(0xFF7AB2),
                   string: c(0xFF8170), comment: c(0x7F8C98), type: c(0x5DD8FF), number: c(0xD9C97C), function: c(0x67B7A4))
            : Look(background: c(0xFFFFFF), text: c(0x000000), lineHighlight: c(0xECF5FF), selection: c(0xB2D7FF), keyword: c(0x9B2393),
                   string: c(0xC41A16), comment: c(0x5D6C79), type: c(0x0B4F79), number: c(0x1C00CF), function: c(0x326D74))
        guard let p = palette, let bg = hex(p.background), let fg = hex(p.text) else { return base }
        return Look(background: bg, text: fg, lineHighlight: hex(p.lineHighlight) ?? bg.blended(withFraction: 0.06, of: fg) ?? bg,
                    selection: hex(p.selection) ?? bg.blended(withFraction: 0.25, of: .controlAccentColor) ?? bg,
                    keyword: hex(p.keyword) ?? base.keyword, string: hex(p.string) ?? base.string, comment: hex(p.comment) ?? base.comment,
                    type: hex(p.type) ?? base.type, number: hex(p.number) ?? base.number, function: hex(p.function) ?? base.function)
    }

    /// The theme's token colors, for code drawn outside the editor (diffs), so both read alike.
    public static var tokenColors: (keyword: NSColor, string: NSColor, number: NSColor, comment: NSColor) {
        let l = look
        return (l.keyword, l.string, l.number, l.comment)
    }

    static var font: NSFont {
        fontName.flatMap { NSFont(name: $0, size: fontSize) } ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Re-applies colors, font and wrapping (at first, and after Settings or the appearance change them).
    public func refreshAppearance() {
        let l = Self.look, f = Self.font, tv = textView
        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: f]).width
        para.tabStops = []
        tv.typingAttributes = [.font: f, .foregroundColor: l.text, .paragraphStyle: para]
        tv.defaultParagraphStyle = para
        if let ts = tv.textStorage, ts.length > 0 { ts.addAttributes(tv.typingAttributes, range: NSRange(location: 0, length: ts.length)) }
        tv.font = f
        tv.backgroundColor = l.background
        tv.insertionPointColor = l.text
        tv.selectedTextAttributes = [.backgroundColor: l.selection]
        tv.lineHighlight = l.lineHighlight
        bracketColor = l.text.withAlphaComponent(0.2)
        scroll.backgroundColor = l.background
        gutter?.color = l.text.withAlphaComponent(0.4)
        gutter?.current = l.text
        gutter?.background = l.background
        gutter?.fit(lines: lineCount)   // a bigger font needs a wider one
        gutter?.needsDisplay = true
        highlighter?.colors = Self.captureColors(l)
        wrap(Self.wrapLines)
        colorVisible()
        tv.needsDisplay = true
    }

    /// Long lines run past the edge (the view widens, a horizontal scroller shows) or wrap at it.
    private func wrap(_ on: Bool) {
        let tv = textView
        guard let tc = tv.textContainer else { return }
        tc.widthTracksTextView = on
        tv.isHorizontallyResizable = !on
        tv.autoresizingMask = [.width]
        scroll.hasHorizontalScroller = !on
        tc.containerSize = NSSize(width: on ? tv.bounds.width : CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        if on { tv.frame.size.width = scroll.contentSize.width }
    }

    /// Tree-sitter capture names (their first part, or the whole for the few that differ) to colors.
    private static func captureColors(_ l: Look) -> [String: NSColor] {
        let keyword = ["keyword", "include", "boolean", "repeat", "conditional", "tag", "exception", "label", "variable.builtin", "constant.builtin"]
        var c: [String: NSColor] = ["comment": l.comment, "string": l.string, "character": l.string, "escape": l.string,
                                    "number": l.number, "float": l.number, "type": l.type, "constructor": l.type, "attribute": l.type,
                                    "function": l.function, "method": l.function,
                                    // Markdown: headings, code, links and list marks
                                    "text.title": l.keyword, "text.literal": l.string, "text.uri": l.type, "text.reference": l.type,
                                    "punctuation.special": l.comment]
        for k in keyword { c[k] = l.keyword }
        return c
    }

    private static func hex(_ s: String?) -> NSColor? { s.flatMap { NSColor(hex: $0) } }
}
