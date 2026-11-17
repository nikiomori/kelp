import Foundation

/// Tab titles and branch names from a task prompt.
enum Naming {
    static let stop: Set<String> = [
        "a", "an", "the", "to", "and", "of", "for", "in", "on", "with", "please", "can", "you", "it",
        "this", "that", "is", "be", "we"
    ]
    /// Returns a branch-name slug of the prompt's first few words, without filler words. "Add a dark-mode toggle to
    /// Settings!" becomes "add-dark-mode-toggle-settings", and "исправь вход" becomes "isprav-vhod". Any script comes
    /// out in Latin letters, because branch names travel best that way, and what has no Latin form is left out.
    static func slug(_ prompt: String, words: Int = 5) -> String {
        let latin =
            prompt.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)
            ?? prompt
        let parts = latin.lowercased().filter(\.isASCII).split { !($0.isLetter || $0.isNumber) }.map(String.init).filter
        { !stop.contains($0) }
        return parts.prefix(words).joined(separator: "-")
    }
    /// Returns a name that fits a tab. It is the prompt's first line without links or paths, cut at a word within 32
    /// characters and capitalised. So "посмотри ресерч http://localhost:8765/p и предложи…" becomes
    /// "Посмотри ресерч и предложи…". Agents that keep a topic in the terminal's title (Claude Code) rename the session
    /// with that topic later.
    static func title(_ prompt: String) -> String {
        let first = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        let words = first.split(separator: " ").filter {
            !$0.contains("://") && !$0.hasPrefix("/") && !$0.hasPrefix("~/")
        }
        var out = ""
        for word in words {
            guard out.count + word.count + 1 <= 32 else {
                out += "…"
                break
            }
            out += (out.isEmpty ? "" : " ") + word
        }
        if out.isEmpty || out == "…" { out = String(first.prefix(31)) + (first.count > 31 ? "…" : "") }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}
