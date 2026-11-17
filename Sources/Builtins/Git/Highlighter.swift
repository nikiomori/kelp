import AppKit

/// A diff line's colours: the editor's tree-sitter captures where the diff has them (`DiffColors`), and plain without.
enum Highlighter {
    /// Longer lines (a minified one) aren't coloured, because nobody reads that far and the captures would pile up.
    static let maxColored = 4000

    /// Colours `s` by its line's captures, which start `from` characters in (past the "+ " marker).
    @MainActor static func attributed(
        _ s: String, spans: [DiffColors.Span], from: Int, font: NSFont, colors: [String: NSColor]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: s, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for span in spans {
            let range = NSRange(location: span.range.location + from, length: span.range.length)
            guard NSMaxRange(range) <= result.length,
                let color = colors[span.name] ?? colors[String(span.name.prefix { $0 != "." })]
            else { continue }
            result.addAttribute(.foregroundColor, value: color, range: range)
        }
        return result
    }
}
