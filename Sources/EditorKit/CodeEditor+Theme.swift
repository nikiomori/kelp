import AppKit
import DesignKit

/// Colors, font and line wrapping, from the IDE theme and Settings › Editor.
extension CodeEditor {
    /// Colors from the IDE theme (hex strings); nil keeps the Xcode-like defaults.
    public struct Palette: Equatable, Sendable {
        public var background, text: String
        public var keyword, string, comment, type, number, function, selection, lineHighlight: String?
        public init(
            background: String, text: String, keyword: String? = nil, string: String? = nil, comment: String? = nil,
            type: String? = nil,
            number: String? = nil, function: String? = nil, selection: String? = nil, lineHighlight: String? = nil
        ) {
            self.background = background
            self.text = text
            self.keyword = keyword
            self.string = string
            self.comment = comment
            self.type = type
            self.number = number
            self.function = function
            self.selection = selection
            self.lineHighlight = lineHighlight
        }
    }
    /// What the theme and Settings › Editor choose for every editor.
    public struct Look: Equatable, Sendable {
        public var palette: Palette?
        public var fontSize: CGFloat
        public var fontName: String?
        /// Off by default, as in most editors: a long line runs past the edge and scrolls. On: it continues on the next row.
        public var wrapLines: Bool
        public var wrappingIndent: WrappingIndent
        public init(
            palette: Palette? = nil, fontSize: CGFloat = 13, fontName: String? = nil, wrapLines: Bool = false,
            wrappingIndent: WrappingIndent = .same
        ) {
            self.palette = palette
            self.fontSize = fontSize
            self.fontName = fontName
            self.wrapLines = wrapLines
            self.wrappingIndent = wrappingIndent
        }
    }
    /// The look every editor has (`apply(look:)`).
    public private(set) static var current = Look()

    /// Gives every editor `look`, the open ones at once (`all`): no host has to remember to tell its own. Returns whether
    /// it changed.
    @discardableResult
    public static func apply(look: Look) -> Bool {
        guard look != current else { return false }
        current = look
        for editor in all.allObjects { editor.refreshAppearance() }
        return true
    }

    /// The colors in use: the palette's, else Xcode's defaults for the appearance.
    struct Colors {
        var background, text, lineHighlight, selection: NSColor
        var keyword, string, comment, type, number, function: NSColor
    }

    static var colors: Colors {
        let dark =
            (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua])
            == .darkAqua
        let color = { (value: Int) in NSColor(hex: value) }
        let base =
            dark
            ? Colors(
                background: color(0x1F1F24), text: color(0xDFDFE0), lineHighlight: color(0x23252B),
                selection: color(0x515B70),
                keyword: color(0xFF7AB2),
                string: color(0xFF8170), comment: color(0x7F8C98), type: color(0x5DD8FF), number: color(0xD9C97C),
                function: color(0x67B7A4)
            )
            : Colors(
                background: color(0xFFFFFF), text: color(0x000000), lineHighlight: color(0xECF5FF),
                selection: color(0xB3D7FF),
                keyword: color(0x9B2393),
                string: color(0xC41A16), comment: color(0x5D6C79), type: color(0x0B4F79), number: color(0x1C00CF),
                function: color(0x326D74)
            )
        guard let palette = current.palette, let bg = hex(palette.background), let fg = hex(palette.text) else {
            return base
        }
        return Colors(
            background: bg, text: fg,
            lineHighlight: hex(palette.lineHighlight) ?? bg.blended(withFraction: 0.06, of: fg) ?? bg,
            selection: hex(palette.selection) ?? bg.blended(withFraction: 0.25, of: .controlAccentColor) ?? bg,
            keyword: hex(palette.keyword) ?? base.keyword, string: hex(palette.string) ?? base.string,
            comment: hex(palette.comment) ?? base.comment,
            type: hex(palette.type) ?? base.type, number: hex(palette.number) ?? base.number,
            function: hex(palette.function) ?? base.function)
    }

    /// The editor's font: code shown outside it (a diff) uses it too.
    public static var font: NSFont {
        current.fontName.flatMap { NSFont(name: $0, size: current.fontSize) }
            ?? .monospacedSystemFont(ofSize: current.fontSize, weight: .regular)
    }

    /// The theme's page: background and text, for code and documents shown outside the editor (a diff, the Markdown
    /// preview), so they sit on the same page as the editor beside them.
    public static var page: (background: NSColor, text: NSColor) {
        let look = Self.colors
        return (look.background, look.text)
    }

    /// Re-applies colors, font and wrapping (at first, and after Settings or the appearance change them).
    public func refreshAppearance() {
        let look = Self.colors, font = Self.font, tv = textView
        let para = NSMutableParagraphStyle()
        para.defaultTabInterval = CGFloat(tabWidth) * (" " as NSString).size(withAttributes: [.font: font]).width
        para.tabStops = []
        tv.typingAttributes = [.font: font, .foregroundColor: look.text, .paragraphStyle: para]
        tv.defaultParagraphStyle = para
        if let ts = tv.textStorage, ts.length > 0 {
            ts.addAttributes(tv.typingAttributes, range: NSRange(location: 0, length: ts.length))
        }
        tv.font = font
        tv.backgroundColor = look.background
        tv.insertionPointColor = look.text
        tv.selectedTextAttributes = [.backgroundColor: look.selection]
        tv.lineHighlight = look.lineHighlight
        bracketColor = look.text.withAlphaComponent(0.2)
        scroll.backgroundColor = look.background
        gutter?.color = look.text.withAlphaComponent(0.4)
        gutter?.current = look.text
        gutter?.background = look.background
        gutter?.fit(lines: lineCount)   // a bigger font needs a wider one
        gutter?.needsDisplay = true
        highlighter?.colors = Self.captureColors(look)
        highlighter?.bracketColors = bracketColors ? [look.number, look.keyword, look.type] : []
        wrap(wrapsHere ?? Self.current.wrapLines || alwaysWraps)
        colored = nil
        colorVisible()
        tv.needsDisplay = true
    }

    /// The column, or the view's edge when that comes first: a container that doesn't track the view needs telling.
    func fitWrapColumn() {
        let tv = textView
        guard let tc = tv.textContainer, !tc.widthTracksTextView, !tv.isHorizontallyResizable, let wrapColumn else {
            return
        }
        let space = (" " as NSString).size(withAttributes: [.font: Self.font]).width
        let width = min(
            tv.bounds.width - 2 * tv.textContainerInset.width, CGFloat(wrapColumn) * space + 2 * tc.lineFragmentPadding)
        if abs(tc.size.width - width) > 0.5 { tc.size = NSSize(width: width, height: .greatestFiniteMagnitude) }
    }

    /// Long lines run past the edge (the view widens, a horizontal scroller shows) or wrap at it.
    private func wrap(_ on: Bool) {
        let tv = textView
        guard let tc = tv.textContainer else { return }
        tc.widthTracksTextView = on && wrapColumn == nil
        tv.isHorizontallyResizable = !on
        tv.autoresizingMask = [.width]
        scroll.hasHorizontalScroller = !on
        tc.containerSize = NSSize(
            width: on ? tv.bounds.width : CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        if on { tv.frame.size.width = scroll.contentSize.width }
        fitWrapColumn()
        guard let wrapping = tc as? WrappingContainer else { return }
        let hanging = on ? Self.current.wrappingIndent : .none,
            space = (" " as NSString).size(withAttributes: [.font: Self.font]).width
        guard wrapping.hanging != hanging || wrapping.space != space else { return }
        wrapping.hanging = hanging
        wrapping.space = space
        tv.layoutManager?.textContainerChangedGeometry(tc)
    }

    /// Tree-sitter capture names (their first part, or the whole for the few that differ) to colors.
    static func captureColors(_ look: Colors) -> [String: NSColor] {
        let keyword = [
            "keyword", "include", "boolean", "repeat", "conditional", "tag", "exception", "label", "variable.builtin",
            "constant.builtin"
        ]
        var colors: [String: NSColor] = [
            "comment": look.comment, "string": look.string, "character": look.string, "escape": look.string,
            "number": look.number, "float": look.number, "type": look.type, "constructor": look.type,
            "attribute": look.type,
            "function": look.function, "method": look.function,
            // Markdown: headings, code, links and list marks
            "text.title": look.keyword, "text.literal": look.string, "text.uri": look.type, "text.reference": look.type,
            "punctuation.special": look.comment
        ]
        for name in keyword { colors[name] = look.keyword }
        return colors
    }

    private static func hex(_ string: String?) -> NSColor? { string.flatMap { NSColor(hex: $0) } }
}
