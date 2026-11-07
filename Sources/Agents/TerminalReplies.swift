import Foundation

/// The conversation a TUI has with its terminal (Grok, Codex… ask "which terminal are you?", "what's your background?"),
/// kept apart from what the user types.
public enum TerminalReplies {
    // Latin-1 maps bytes 1:1, so regexes work on raw terminal bytes (split UTF-8 included) and convert back losslessly.
    private static let queries = try? NSRegularExpression(
        pattern: [
            #"\x1B\[[>=]?[0-9;]*c"#,   // device attributes
            #"\x1B\[>[0-9;]*q"#,   // XTVERSION
            #"\x1B\[\??[0-9;]*n"#,   // status / cursor position
            #"\x1B\[\?u"#,   // kitty keyboard flags
            #"\x1B\[\??[0-9;]*\$p"#,   // DECRQM
            #"\x1B\[(?:1[1-9]|2[01])(?:;[0-9]*)*t"#,   // window size reports
            #"\x1B\][0-9]+(?:;[^\x07\x1B]*)?;\?(?:\x07|\x1B\\)"#,   // OSC color / clipboard queries
            #"\x1B\]52;[^\x07\x1B]*(?:\x07|\x1B\\)"#,   // OSC 52 copies: replayed, they'd put old text on the clipboard
            #"\x1BP[+$]q[^\x1B]*\x1B\\"#,   // XTGETTCAP, DECRQSS
            #"\x1B_G[^\x1B]*a=q[^\x1B]*\x1B\\"#,   // kitty graphics "can you show images?" (Claude Code at start)
            #"\x1BZ"#
        ].joined(separator: "|"))
    private static let replies = try? NSRegularExpression(
        pattern: [
            #"\x1B\[[?>=]?[0-9;]*\$?[cRnyt]"#,   // attributes, cursor position, status, modes, window size
            #"\x1B\[\?[0-9;]*u"#,   // kitty keyboard flags (a key press has no "?")
            #"\x1B\[[IO]"#,   // focus in / out
            #"\x1B\][0-9]+;[^\x07\x1B]*(?:\x07|\x1B\\)"#,   // OSC answers
            #"\x1BP[^\x1B]*\x1B\\"#,   // DCS answers (XTVERSION "ghostty 1.3…")
            #"\x1B_G[^\x1B]*\x1B\\"#   // kitty graphics answers ("i=31;OK"): taken for a key, they let
            // a launch prompt's Enter answer "trust this folder?" with No
        ].joined(separator: "|"))

    /// History to replay into a new terminal, minus the agent's old questions to its terminal: answered again, the
    /// answers would reach the agent as typing (">|ghostty 1.3.2" in its prompt). Its old clipboard copies go too.
    public static func withoutQueries(_ d: Data) -> Data {
        guard let q = queries, let s = String(data: d, encoding: .isoLatin1) else { return d }
        let out = q.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        return out.data(using: .isoLatin1) ?? d
    }

    /// Input made only of the terminal answering the agent: not the user doing anything.
    public static func isReply(_ d: Data) -> Bool {
        guard d.first == 0x1B, let r = replies, let s = String(data: d, encoding: .isoLatin1) else { return false }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "").isEmpty
    }
}
