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
                let n = counts[name, default: 0]
                counts[name] = n + 1
                prefix = "\(name).\(n)."
                continue
            }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                prefix = Self.key(line[line.index(after: line.startIndex)..<end]) + "."
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = prefix + Self.key(line[..<eq])
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let q = ["\"\"\"", "'''"].first(where: v.hasPrefix) {
                var body = String(v.dropFirst(3))
                while !body.contains(q), let next = lines.popFirst() { body += "\n" + next }
                guard let close = body.range(of: q) else { continue }
                var s = String(body[..<close.lowerBound])
                if s.hasPrefix("\n") { s.removeFirst() }   // a newline right after the quotes isn't part of it
                pairs.append((key, q == "'''" ? s : Self.unescape(s)))
            } else if v.hasPrefix("[") {
                while !Self.closes(v), let next = lines.popFirst() { v += "\n" + next }
                pairs.append((key, Self.strings(Substring(v))))
            } else if v.hasPrefix("\"") || v.hasPrefix("'") {
                if let s = Self.strings(Substring(v)).first { pairs.append((key, s)) }
            } else if v.hasPrefix("true") || v.hasPrefix("false") {
                pairs.append((key, v.hasPrefix("true")))
            }
        }
    }

    func string(_ key: String) -> String? { pairs.first { $0.key == key }?.value as? String }
    func strings(_ key: String) -> [String]? { pairs.first { $0.key == key }?.value as? [String] }
    func bool(_ key: String) -> Bool { pairs.first { $0.key == key }?.value as? Bool ?? false }
    /// The names right under `prefix` ("scripts.run." → "dev", "test"), in the file's order.
    func names(under prefix: String) -> [String] {
        var out: [String] = []
        for p in pairs where p.key.hasPrefix(prefix) {
            let name = String(p.key.dropFirst(prefix.count).prefix { $0 != "." })
            if !name.isEmpty, !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// `a . "b c"` → `a.b c`. Limit: a quoted part holding a dot splits there.
    static func key(_ s: Substring) -> String {
        s.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .joined(separator: ".")
    }

    /// Whether an array value is whole: its "[" closed, brackets inside strings left out.
    static func closes(_ v: String) -> Bool {
        var depth = 0, quote: Character?, escaped = false, comment = false
        for ch in v {
            if comment { comment = ch != "\n"; continue }
            if let q = quote {
                if escaped { escaped = false } else if ch == "\\" && q == "\"" { escaped = true } else if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" { quote = ch } else if ch == "#" { comment = true }
            else if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1; if depth == 0 { return true } }
        }
        return false
    }

    /// The one-line strings in `s`, in order; a comment outside them runs to the end of its line.
    static func strings(_ s: Substring) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, escaped = false, comment = false
        for ch in s {
            if comment { comment = ch != "\n"; continue }
            if let q = quote {
                if escaped {
                    cur += "\\" + String(ch)   // unescaped with the rest
                    escaped = false
                } else if ch == "\\" && q == "\"" {
                    escaped = true
                } else if ch == q {
                    out.append(q == "\"" ? unescape(cur) : cur)
                    (cur, quote) = ("", nil)
                } else {
                    cur.append(ch)
                }
            } else if ch == "\"" || ch == "'" { quote = ch } else if ch == "#" { comment = true }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var out = "", it = s.makeIterator()
        while let ch = it.next() {
            guard ch == "\\", let n = it.next() else { out.append(ch); continue }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"", "\\": out.append(n)
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }
}

/// JSON as editors and some tools write it, comments and trailing commas too (JSON5, as package.json is read).
enum JSONC {
    static func object(_ text: String) -> [String: Any]? { value(text) as? [String: Any] }

    static func value(_ text: String) -> Any? {
        Log.session.attempt("reading another tool's project file") { try JSONSerialization.jsonObject(with: Data(text.utf8), options: .json5Allowed) }
    }
}
