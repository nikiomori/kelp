import AppKit

extension CodeEditor {
    /// A server's edit to the text, 0-based, in UTF-16 units.
    public struct TextEdit: Equatable, Sendable {
        public let line: Int, column: Int, endLine: Int, endColumn: Int, text: String
        public init(line: Int, column: Int, endLine: Int, endColumn: Int, text: String) {
            self.line = line; self.column = column; self.endLine = endLine; self.endColumn = endColumn; self.text = text
        }
    }

    public struct Completion: Equatable, Sendable {
        public var label: String
        public var detail: String?
        public var insert: String
        /// "method", "keyword"…
        public var kind: String?
        public var documentation: String?
        /// `insert` has tab stops ($1, ${2:name}).
        public var snippet = false
        /// What the server says replaces what; else the word at the cursor.
        public var edit: TextEdit?
        /// More edits with it, as an import an item needs.
        public var more: [TextEdit] = []
        public init(label: String, detail: String? = nil, insert: String, kind: String? = nil, documentation: String? = nil, snippet: Bool = false,
                    edit: TextEdit? = nil, more: [TextEdit] = []) {
            self.label = label; self.detail = detail; self.insert = insert; self.kind = kind; self.documentation = documentation
            self.snippet = snippet; self.edit = edit; self.more = more
        }
    }
}

enum CompletionFilter {
    /// What matches `typed`, its letters in order: those starting with it first, then at a word, then the rest, each in the
    /// server's order.
    static func ranked(_ items: [CodeEditor.Completion], typed: String) -> [CodeEditor.Completion] {
        guard !typed.isEmpty else { return items }
        let t = typed.lowercased()
        func rank(_ label: String) -> Int? {
            let l = label.lowercased()
            if l.hasPrefix(t) { return 0 }
            if l.contains(t) { return 1 }
            var rest = Substring(t)
            for c in l where c == rest.first { rest = rest.dropFirst() }
            return rest.isEmpty ? 2 : nil
        }
        return items.enumerated().compactMap { i, c in rank(c.label).map { (c, $0, i) } }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }
}

/// A snippet's text and its tab stops.
enum Snippet {
    /// `stops`: where each stop is in `text`, those of one number together, in the order Tab goes: 1, 2… and 0 last.
    static func parse(_ s: String) -> (text: String, stops: [[NSRange]]) {
        var out = "", found: [Int: [NSRange]] = [:]
        read(Array(s.unicodeScalars), into: &out, &found)
        mirror(&out, &found)
        let order = found.keys.filter { $0 != 0 }.sorted() + (found[0] == nil ? [] : [0])
        return (out, order.compactMap { found[$0] })
    }

    /// A stop's empty places show what its placeholder says: `${1:name} = $1` starts as `name = name`.
    private static func mirror(_ text: inout String, _ found: inout [Int: [NSRange]]) {
        let s = NSMutableString(string: text)
        for n in found.keys.sorted() {
            while let places = found[n], let model = places.first(where: { $0.length > 0 }), let k = places.firstIndex(where: { $0.length == 0 }) {
                let value = s.substring(with: model), at = places[k].location, added = (value as NSString).length
                s.insert(value, at: at)
                found = found.mapValues { list in
                    list.map { r in
                        if r.location >= at { return NSRange(location: r.location + added, length: r.length) }
                        return NSMaxRange(r) > at ? NSRange(location: r.location, length: r.length + added) : r
                    }
                }
                found[n]?[k] = NSRange(location: at, length: added)
            }
        }
        text = s as String
    }

    /// Multi-line text takes the indent of the line it goes in, its tabs the file's indent.
    static func fitted(_ s: String, indent: String, unit: String) -> String {
        s.replacingOccurrences(of: "\t", with: unit).replacingOccurrences(of: "\n", with: "\n" + indent)
    }

    private static func read(_ c: [Unicode.Scalar], into out: inout String, _ found: inout [Int: [NSRange]]) {
        var i = 0
        func number() -> Int? {
            var n: Int?
            while i < c.count, let d = Int(String(c[i])) {
                n = (n ?? 0) * 10 + d
                i += 1
            }
            return n
        }
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count {
                out.unicodeScalars.append(c[i + 1])
                i += 2
            } else if c[i] == "$", i + 1 < c.count, c[i + 1] != "{" {
                i += 1
                if let n = number() { found[n, default: []].append(NSRange(location: (out as NSString).length, length: 0)) } else { out.append("$") }
            } else if c[i] == "$", i + 1 < c.count {
                i += 2
                guard let n = number() else { continue }
                let start = (out as NSString).length
                if i < c.count, c[i] == ":" || c[i] == "|" {
                    let choice = c[i] == "|"
                    i += 1
                    var depth = 0, inner: [Unicode.Scalar] = []
                    while i < c.count, depth > 0 || c[i] != "}" {
                        if c[i] == "{" { depth += 1 } else if c[i] == "}" { depth -= 1 }
                        inner.append(c[i])
                        i += 1
                    }
                    if choice {   // ${1|one,two|}: the first
                        out += String(String.UnicodeScalarView(inner)).split(separator: "|").first?.split(separator: ",").first.map(String.init) ?? ""
                    } else {
                        var text = "", nested: [Int: [NSRange]] = [:]
                        read(inner, into: &text, &nested)
                        for (k, v) in nested { found[k, default: []] += v.map { NSRange(location: $0.location + start, length: $0.length) } }
                        out += text
                    }
                }
                i += 1   // past the }
                found[n, default: []].append(NSRange(location: start, length: (out as NSString).length - start))
            } else {
                out.unicodeScalars.append(c[i])
                i += 1
            }
        }
    }
}
