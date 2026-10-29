import Foundation

/// OSC 0 / OSC 2, the window title a program sets. Claude Code puts a short topic of the conversation there
/// ("✳ Ревью и оценка приложения"); other agents their own name or folder ("grok", "π - Kelp", "Qwen - shop"),
/// which say nothing about the task.
public enum TerminalTitle {
    static let starts = ["\u{1B}]0;", "\u{1B}]2;"]

    /// Titles set in a chunk of output, in order. `carry` keeps a sequence cut off at the end of one read for the next.
    public static func scan(_ chunk: String, carry: inout String) -> [String] { oscBodies(chunk, starts: starts, limit: 512, carry: &carry) }

    /// The topic in a title, without the spinner in front; nil when it only names the program (`names`: its id and
    /// name) or the folder, or reads like a path. A spinner after the program's mark ("π ⠧ 󰊗 Fix login", omp) and
    /// icon-font glyphs go wherever they are: each frame would rename the session and its workspace, ~12 times a second.
    public static func topic(_ title: String, names: [String]) -> String? {
        let bare = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            !(0x2800...0x28FF).contains($0.value) && $0.properties.generalCategory != .privateUse
        })).split(separator: " ").joined(separator: " ")
        let t = String(bare.drop { !($0.isLetter || $0.isNumber) }).trimmingCharacters(in: .whitespaces)
        let low = t.lowercased()
        guard !t.isEmpty, t.count <= 80, !t.contains("/"), !t.contains("~") else { return nil }
        return names.contains { $0.count >= 2 && low.contains($0.lowercased()) } ? nil : t
    }
}

/// The bodies of OSC sequences opened by one of `starts` (BEL or ESC ends one), in order. `carry` keeps a sequence cut
/// off at the end of one read for the next; one still open after `limit` bytes is dropped.
func oscBodies(_ chunk: String, starts: [String], limit: Int, carry: inout String) -> [String] {
    var s = carry + chunk
    carry = ""
    var out: [String] = []
    while let r = starts.compactMap({ s.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
        let body = s[r.upperBound...]
        guard let end = body.firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" }) else {
            if body.utf8.count < limit { carry = String(s[r.lowerBound...]) }   // unfinished: wait for the rest
            return out
        }
        out.append(String(body[..<end]))
        s = String(body[body.index(after: end)...])
    }
    // "…\u{1B}]" at the very end: the start of a sequence the next read completes.
    if let i = s.lastIndex(of: "\u{1B}"), starts.contains(where: { $0.hasPrefix(String(s[i...])) }) { carry = String(s[i...]) }
    return out
}
