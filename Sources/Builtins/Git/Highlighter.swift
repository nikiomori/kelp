import AppKit
import EditorKit
import KelpKit

/// A diff line's colours: the editor's tree-sitter captures where the diff has them (`DiffColors`), else a small regex
/// highlighter (a language without a grammar, a side too long to parse, lines opened between changes).
enum Highlighter {
    static let keywords: [String: [String]] = {
        let c = ["if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default", "struct", "class", "enum", "static",
                 "const", "void", "int", "char", "bool", "true", "false", "null", "nil", "new", "this", "self", "import", "include"]
        return [
            "swift": ["func", "let", "var", "guard", "async", "await", "protocol", "extension", "public", "private", "internal",
                "final", "init", "try", "throws", "in", "where", "some", "actor"] + c,
            "ts": ["function", "const", "let", "var", "async", "await", "export", "import", "from", "interface", "type", "extends",
                   "implements", "undefined", "typeof"] + c,
            "js": ["function", "const", "let", "var", "async", "await", "export", "import", "from", "undefined", "typeof"] + c,
            "py": ["def", "class", "import", "from", "as", "with", "lambda", "yield", "None", "True", "False", "elif",
                   "except", "try", "finally", "raise", "pass", "async", "await", "not", "and", "or", "is", "in"] + c,
            "go": ["func", "package", "import", "var", "type", "interface", "range", "go", "defer", "chan", "map", "select", "fallthrough"] + c,
            "rs": ["fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "match", "loop", "where", "async", "await", "Self", "crate",
                   "move", "ref", "unsafe"] + c,
            "json": ["true", "false", "null"], "yaml": ["true", "false", "null"]
        ]
    }()
    static let alias = ["tsx": "ts", "jsx": "js", "mjs": "js", "yml": "yaml", "py": "py"]

    /// Keyword, number, string and comment patterns, compiled once per language: a diff paints each row as it scrolls in.
    @MainActor private static var patterns: [String: [NSRegularExpression]] = [:]
    static let maxColored = 4000

    @MainActor static func attributed(_ s: String, ext: String, font: NSFont) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let lang = alias[ext] ?? ext
        guard s.utf16.count <= maxColored, let kw = keywords[lang] else { return a }   // a minified line: 2 MB took 25 s
        let res = patterns[lang] ?? [#"\b(\#(kw.joined(separator: "|")))\b"#, #"\b\d+(\.\d+)?\b"#, #""(\\.|[^"\\])*"|'(\\.|[^'\\])*'"#,
                                     lang == "py" || lang == "yaml" ? #"#.*$"# : #"//.*$"#].compactMap { try? NSRegularExpression(pattern: $0) }
        patterns[lang] = res
        // The editor theme's colors, so a diff reads like the file it changes.
        let c = CodeEditor.tokenColors
        for (re, color) in zip(res, [c.keyword, c.number, c.string, c.comment]) {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) { a.addAttribute(.foregroundColor, value: color, range: m.range) }
        }
        return a
    }

    /// `s` coloured by its line's captures, which start `from` characters in (past the "+ " marker).
    @MainActor static func attributed(_ s: String, spans: [DiffColors.Span], from: Int, font: NSFont, colors: [String: NSColor]) -> NSAttributedString {
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for span in spans {
            let r = NSRange(location: span.range.location + from, length: span.range.length)
            guard NSMaxRange(r) <= a.length, let c = colors[span.name] ?? colors[String(span.name.prefix { $0 != "." })] else { continue }
            a.addAttribute(.foregroundColor, value: c, range: r)
        }
        return a
    }
}
