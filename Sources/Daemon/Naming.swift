import Foundation

/// Tab titles and branch names from a task prompt.
enum Naming {
    static let stop: Set<String> = [
        "a", "an", "the", "to", "and", "of", "for", "in", "on", "with", "please", "can", "you", "it",
        "this", "that", "is", "be", "we"
    ]
    /// "Add a dark-mode toggle to Settings!" -> "add-dark-mode-toggle-settings"; "исправь вход" -> "isprav-vhod": any script
    /// comes out in Latin letters, as branch names travel best, and what has none is left out.
    static func slug(_ s: String, words: Int = 5) -> String {
        let latin =
            s.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s
        let parts = latin.lowercased().filter(\.isASCII).split { !($0.isLetter || $0.isNumber) }.map(String.init).filter
        { !stop.contains($0) }
        return parts.prefix(words).joined(separator: "-")
    }
    /// A name that fits a tab: the prompt's first line without links or paths, cut at a word within 32 characters,
    /// capitalised. "посмотри ресерч http://localhost:8765/p и предложи…" → "Посмотри ресерч и предложи…".
    /// Agents that keep a topic in the terminal's title (Claude Code) rename the session with it later.
    static func title(_ s: String) -> String {
        let first = s.split(separator: "\n").first.map(String.init) ?? s
        let words = first.split(separator: " ").filter {
            !$0.contains("://") && !$0.hasPrefix("/") && !$0.hasPrefix("~/")
        }
        var out = ""
        for w in words {
            guard out.count + w.count + 1 <= 32 else {
                out += "…"
                break
            }
            out += (out.isEmpty ? "" : " ") + w
        }
        if out.isEmpty || out == "…" { out = String(first.prefix(31)) + (first.count > 31 ? "…" : "") }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}
