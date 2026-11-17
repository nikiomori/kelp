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
            #"\x1B\]52;[^\x07\x1B]*(?:\x07|\x1B\\)"#,   // OSC 52 copies, as a replay puts old text on the clipboard
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
            #"\x1B_G[^\x1B]*\x1B\\"#   // kitty graphics answers ("i=31;OK"). Read as keys, they made
            // a launch prompt's Enter answer "trust this folder?" with No
        ].joined(separator: "|"))

    /// Returns history to replay into a new terminal, without the agent's old questions to its terminal. If they were
    /// answered again, the answers would reach the agent as typing (">|ghostty 1.3.2" in its prompt). The agent's old
    /// clipboard copies are removed too.
    public static func withoutQueries(_ data: Data) -> Data {
        guard let pattern = queries, let text = String(data: data, encoding: .isoLatin1) else { return data }
        let out = pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return out.data(using: .isoLatin1) ?? data
    }

    /// Whether input is made only of the terminal answering the agent, and not of the user doing anything.
    public static func isReply(_ data: Data) -> Bool {
        guard data.first == 0x1B, let pattern = replies, let text = String(data: data, encoding: .isoLatin1) else {
            return false
        }
        return pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        ).isEmpty
    }
}
