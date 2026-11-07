import AppKit

extension CodeEditor {
    /// A server's edit to the text, 0-based, in UTF-16 units.
    public struct TextEdit: Equatable, Sendable {
        public let line: Int, column: Int, endLine: Int, endColumn: Int, text: String
        public init(line: Int, column: Int, endLine: Int, endColumn: Int, text: String) {
            self.line = line
            self.column = column
            self.endLine = endLine
            self.endColumn = endColumn
            self.text = text
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
        public init(
            label: String, detail: String? = nil, insert: String, kind: String? = nil, documentation: String? = nil,
            snippet: Bool = false,
            edit: TextEdit? = nil, more: [TextEdit] = []
        ) {
            self.label = label
            self.detail = detail
            self.insert = insert
            self.kind = kind
            self.documentation = documentation
            self.snippet = snippet
            self.edit = edit
            self.more = more
        }
    }
}

enum CompletionFilter {
    /// What matches `typed`, its letters in order: those starting with it first, then at a word, then the rest, each in the
    /// server's order.
    static func ranked(_ items: [CodeEditor.Completion], typed: String) -> [CodeEditor.Completion] {
        guard !typed.isEmpty else { return items }
        let query = typed.lowercased()
        func rank(_ label: String) -> Int? {
            let name = label.lowercased()
            if name.hasPrefix(query) { return 0 }
            if name.contains(query) { return 1 }
            var rest = Substring(query)
            for letter in name where letter == rest.first { rest = rest.dropFirst() }
            return rest.isEmpty ? 2 : nil
        }
        return items.enumerated().compactMap { index, item in rank(item.label).map { (item, $0, index) } }.sorted {
            ($0.1, $0.2) < ($1.1, $1.2)
        }.map(\.0)
    }
}

/// A snippet's text and its tab stops.
enum Snippet {
    /// `stops`: where each stop is in `text`, those of one number together, in the order Tab goes: 1, 2… and 0 last.
    static func parse(_ source: String) -> (text: String, stops: [[NSRange]]) {
        var out = "", found: [Int: [NSRange]] = [:]
        read(Array(source.unicodeScalars), into: &out, &found)
        mirror(&out, &found)
        let order = found.keys.filter { $0 != 0 }.sorted() + (found[0] == nil ? [] : [0])
        return (out, order.compactMap { found[$0] })
    }

    /// A stop's empty places show what its placeholder says: `${1:name} = $1` starts as `name = name`.
    private static func mirror(_ text: inout String, _ found: inout [Int: [NSRange]]) {
        let buffer = NSMutableString(string: text)
        for stop in found.keys.sorted() {
            while let places = found[stop], let model = places.first(where: { $0.length > 0 }),
                let empty = places.firstIndex(where: { $0.length == 0 })
            {
                let value = buffer.substring(with: model), at = places[empty].location,
                    added = (value as NSString).length
                buffer.insert(value, at: at)
                found = found.mapValues { list in
                    list.map { range in
                        if range.location >= at {
                            return NSRange(location: range.location + added, length: range.length)
                        }
                        return NSMaxRange(range) > at
                            ? NSRange(location: range.location, length: range.length + added) : range
                    }
                }
                found[stop]?[empty] = NSRange(location: at, length: added)
            }
        }
        text = buffer as String
    }

    /// Multi-line text takes the indent of the line it goes in, its tabs the file's indent.
    static func fitted(_ text: String, indent: String, unit: String) -> String {
        text.replacingOccurrences(of: "\t", with: unit).replacingOccurrences(of: "\n", with: "\n" + indent)
    }

    private static func read(_ scalars: [Unicode.Scalar], into out: inout String, _ found: inout [Int: [NSRange]]) {
        var index = 0
        func number() -> Int? {
            var value: Int?
            while index < scalars.count, let digit = Int(String(scalars[index])) {
                value = (value ?? 0) * 10 + digit
                index += 1
            }
            return value
        }
        while index < scalars.count {
            if scalars[index] == "\\", index + 1 < scalars.count {
                out.unicodeScalars.append(scalars[index + 1])
                index += 2
            } else if scalars[index] == "$", index + 1 < scalars.count, scalars[index + 1] != "{" {
                index += 1
                if let stop = number() {
                    found[stop, default: []].append(NSRange(location: (out as NSString).length, length: 0))
                } else {
                    out.append("$")
                }
            } else if scalars[index] == "$", index + 1 < scalars.count {
                index += 2
                guard let stop = number() else { continue }
                let start = (out as NSString).length
                if index < scalars.count, scalars[index] == ":" || scalars[index] == "|" {
                    let choice = scalars[index] == "|"
                    index += 1
                    var depth = 0, inner: [Unicode.Scalar] = []
                    while index < scalars.count, depth > 0 || scalars[index] != "}" {
                        if scalars[index] == "{" { depth += 1 } else if scalars[index] == "}" { depth -= 1 }
                        inner.append(scalars[index])
                        index += 1
                    }
                    if choice {   // ${1|one,two|}: the first
                        out +=
                            String(String.UnicodeScalarView(inner)).split(separator: "|").first?.split(separator: ",")
                            .first.map(String.init) ?? ""
                    } else {
                        var text = "", nested: [Int: [NSRange]] = [:]
                        read(inner, into: &text, &nested)
                        for (nestedStop, ranges) in nested {
                            found[nestedStop, default: []] += ranges.map {
                                NSRange(location: $0.location + start, length: $0.length)
                            }
                        }
                        out += text
                    }
                }
                index += 1   // past the }
                found[stop, default: []].append(NSRange(location: start, length: (out as NSString).length - start))
            } else {
                out.unicodeScalars.append(scalars[index])
                index += 1
            }
        }
    }
}
