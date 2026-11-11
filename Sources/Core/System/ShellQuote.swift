import Foundation

/// Words for a shell, or for an agent's prompt, that come out as written.
public enum ShellQuote {
    /// A path dropped into an agent's prompt: backslash escapes, which shells and agents (Claude Code, Codex) all read;
    /// Claude strips only one pair of quotes, so the POSIX `'…'\''…'` form leaks into the path (Ghostty does the same).
    public static func escapedPath(_ path: String) -> String {
        var out = ""
        for char in path {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(char) { out.append("\\") }
            out.append(char)
        }
        return out
    }

    /// One shell word, single-quoted (`'…'\''…'`): commands Kelp writes itself. The shell expands nothing inside.
    public static func word(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A basic string, as both TOML and JSON write one (for text with no control characters).
    public static func doubleQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A command line split as a shell would: whitespace apart, '…' as it is, "…" with \" and \\ inside, \ before
    /// one char.
    public static func words(_ text: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for c in text {
            if escaped {
                word.append(c)
                escaped = false
            } else if c == "\\" && quote != "'" {
                escaped = true
            } else if let open = quote {
                if c == open { quote = nil } else { word.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                started = true
            } else if c.isWhitespace {
                if started || !word.isEmpty { words.append(word) }
                word = ""
                started = false
            } else {
                word.append(c)
            }
        }
        if started || !word.isEmpty { words.append(word) }
        return words
    }
}
