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
}
