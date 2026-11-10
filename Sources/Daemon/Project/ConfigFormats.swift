import Foundation

/// Just enough TOML for other tools' project files (`ImportedConfig`): `[tables]`, `[[arrays of tables]]` (numbered
/// `name.0.`, `name.1.`), and `key = value` where a value is a string ("…", '…', """…""", '''…'''), an array of strings or
/// a boolean. Anything else (numbers, dates, inline tables) is left out. Pairs keep the file's order.
struct MiniTOML {
    private(set) var pairs: [(key: String, value: Any)] = []

    init(_ text: String) {
        var prefix = "", counts: [String: Int] = [:]
        var lines = text.components(separatedBy: .newlines)[...]
        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[["), let end = line.range(of: "]]") {
                let name = Self.key(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound])
                let index = counts[name, default: 0]
                counts[name] = index + 1
                prefix = "\(name).\(index)."
                continue
            }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                prefix = Self.key(line[line.index(after: line.startIndex)..<end]) + "."
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = prefix + Self.key(line[..<eq])
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = ["\"\"\"", "'''"].first(where: value.hasPrefix) {
                var body = String(value.dropFirst(3))
                while !body.contains(quote), let next = lines.popFirst() { body += "\n" + next }
                guard let close = body.range(of: quote) else { continue }
                var content = String(body[..<close.lowerBound])
                // A newline right after the quotes isn't part of it.
                if content.hasPrefix("\n") { content.removeFirst() }
                pairs.append((key, quote == "'''" ? content : Self.unescape(content)))
            } else if value.hasPrefix("[") {
                while !Self.closes(value), let next = lines.popFirst() { value += "\n" + next }
                pairs.append((key, Self.strings(Substring(value))))
            } else if value.hasPrefix("\"") || value.hasPrefix("'") {
                if let content = Self.strings(Substring(value)).first { pairs.append((key, content)) }
            } else if value.hasPrefix("true") || value.hasPrefix("false") {
                pairs.append((key, value.hasPrefix("true")))
            }
        }
    }

    func string(_ key: String) -> String? { pairs.first { $0.key == key }?.value as? String }
    func strings(_ key: String) -> [String]? { pairs.first { $0.key == key }?.value as? [String] }
    func bool(_ key: String) -> Bool { pairs.first { $0.key == key }?.value as? Bool ?? false }
    /// The names right under `prefix` ("scripts.run." → "dev", "test"), in the file's order.
    func names(under prefix: String) -> [String] {
        var out: [String] = []
        for pair in pairs where pair.key.hasPrefix(prefix) {
            let name = String(pair.key.dropFirst(prefix.count).prefix { $0 != "." })
            if !name.isEmpty, !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// `a . "b c"` → `a.b c`. Limit: a quoted part holding a dot splits there.
    static func key(_ path: Substring) -> String {
        path.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        .joined(separator: ".")
    }

    /// Whether an array value is whole: its "[" closed, brackets inside strings left out.
    static func closes(_ value: String) -> Bool {
        var depth = 0, quote: Character?, escaped = false, comment = false
        for ch in value {
            if comment {
                comment = ch != "\n"
                continue
            }
            if let opening = quote {
                if escaped {
                    escaped = false
                } else if ch == "\\" && opening == "\"" {
                    escaped = true
                } else if ch == opening {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                comment = true
            } else if ch == "[" {
                depth += 1
            } else if ch == "]" {
                depth -= 1
                if depth == 0 { return true }
            }
        }
        return false
    }

    /// The one-line strings in `text`, in order; a comment outside them runs to the end of its line.
    static func strings(_ text: Substring) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, escaped = false, comment = false
        for ch in text {
            if comment {
                comment = ch != "\n"
                continue
            }
            if let opening = quote {
                if escaped {
                    cur += "\\" + String(ch)   // unescaped with the rest
                    escaped = false
                } else if ch == "\\" && opening == "\"" {
                    escaped = true
                } else if ch == opening {
                    out.append(opening == "\"" ? unescape(cur) : cur)
                    (cur, quote) = ("", nil)
                } else {
                    cur.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                comment = true
            }
        }
        return out
    }

    static func unescape(_ text: String) -> String {
        var out = "", it = text.makeIterator()
        while let ch = it.next() {
            guard ch == "\\", let next = it.next() else {
                out.append(ch)
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"", "\\": out.append(next)
            default:
                out.append("\\")
                out.append(next)
            }
        }
        return out
    }
}

/// JSON as editors and some tools write it, comments and trailing commas too (JSON5, as package.json is read).
enum JSONC {
    static func object(_ text: String) -> [String: Any]? { value(text) as? [String: Any] }

    static func value(_ text: String) -> Any? {
        Log.session.attempt("reading another tool's project file") {
            try JSONSerialization.jsonObject(with: Data(text.utf8), options: .json5Allowed)
        }
    }
}
