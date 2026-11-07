import AppKit
@preconcurrency import CodeEditLanguages
@preconcurrency import SwiftTreeSitter

/// A file's tree-sitter grammar for code drawn outside the editor (a diff's lines), so it colours as the editor does: a
/// text parsed on any thread, its captures coloured by the theme (`CodeEditor.syntaxColors`) on the main one.
public struct CodeGrammar: Sendable {
    private let language: Language, query: Query

    /// The grammar for a file by its name; nil for a language without one. On the main thread: the queries are made there.
    @MainActor public init?(fileName: String) {
        let lang = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: fileName))
        guard let treeLanguage = lang.language, let highlightQuery = TreeSitterModel.shared.query(for: lang.id) else {
            return nil
        }
        language = treeLanguage
        query = highlightQuery
    }

    /// The capture names in `text` by UTF-16 range, the less specific first (a later, narrower one wins).
    public func highlights(_ text: String) -> [(range: NSRange, name: String)] {
        let parser = Parser(), string = text as NSString
        guard (try? parser.setLanguage(language)) != nil, let tree = parser.parse(text) else { return [] }
        // Predicates read pieces by UTF-16 range, as the editor's do: NSString's are O(1) to cut.
        let piece: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            NSMaxRange(range) <= string.length ? string.substring(with: range) : nil
        }
        return query.execute(in: tree).resolve(with: .init(textProvider: piece)).highlights().map {
            ($0.range, $0.name)
        }
    }
}

extension CodeEditor {
    /// The theme's colour for each capture name, as the editor colours it; a name missing here goes by its first part.
    public static var syntaxColors: [String: NSColor] { captureColors(look) }
}
