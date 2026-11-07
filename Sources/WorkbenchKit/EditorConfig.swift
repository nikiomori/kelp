import Foundation

/// What an `.editorconfig` asks of a file (editorconfig.org): nil what it leaves alone.
public struct EditorRules: Equatable, Sendable {
    public var tabSize: Int?, insertSpaces: Bool?, trimTrailingWhitespace: Bool?, insertFinalNewline: Bool?
    public init() {}

    /// `self` from a nearer file, `other` from one further up: the nearer one's say stands.
    public func over(_ other: EditorRules) -> EditorRules {
        var merged = self
        merged.tabSize = tabSize ?? other.tabSize
        merged.insertSpaces = insertSpaces ?? other.insertSpaces
        merged.trimTrailingWhitespace = trimTrailingWhitespace ?? other.trimTrailingWhitespace
        merged.insertFinalNewline = insertFinalNewline ?? other.insertFinalNewline
        return merged
    }
}

public enum EditorConfig {
    /// `file`, relative to the config's folder. `root`: `root = true`, no need to look further up.
    public static func read(_ text: String, file: String) -> (rules: EditorRules, root: Bool) {
        var rules = EditorRules(), root = false, inSection = false, section = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = true
                inSection = matches(String(line.dropFirst().dropLast()), file)
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard parts.count == 2 else { continue }
            if !section, parts[0] == "root" { root = parts[1] == "true" }
            if inSection { apply(parts[0], parts[1], to: &rules) }
        }
        return (rules, root)
    }

    private static func apply(_ key: String, _ value: String, to r: inout EditorRules) {
        switch key {
        case "indent_style": r.insertSpaces = value == "space" ? true : value == "tab" ? false : nil
        case "indent_size", "tab_width": if let size = Int(value), size > 0 { r.tabSize = size }
        case "trim_trailing_whitespace":
            r.trimTrailingWhitespace = value == "true" ? true : value == "false" ? false : nil
        case "insert_final_newline": r.insertFinalNewline = value == "true" ? true : value == "false" ? false : nil
        default: break
        }
    }

    /// A section's glob: without a `/` it matches a file's name at any depth.
    static func matches(_ glob: String, _ file: String) -> Bool {
        let name = glob.contains("/") ? file : (file as NSString).lastPathComponent
        let bare = glob.hasPrefix("/") ? String(glob.dropFirst()) : glob
        guard let pattern = try? NSRegularExpression(pattern: "^" + regex(bare) + "$") else { return false }
        return pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static func regex(_ glob: String) -> String {
        var out = "", braces = 0, i = glob.startIndex
        while i < glob.endIndex {
            let character = glob[i], next = glob.index(after: i)
            switch character {
            case "*":
                if next < glob.endIndex, glob[next] == "*" {
                    out += ".*"
                    i = glob.index(after: next)
                    continue
                }
                out += "[^/]*"
            case "?": out += "[^/]"
            case "{":
                braces += 1
                out += "(?:"
            case "}" where braces > 0:
                braces -= 1
                out += ")"
            case "," where braces > 0: out += "|"
            default: out += NSRegularExpression.escapedPattern(for: String(character))
            }
            i = next
        }
        return out
    }
}
