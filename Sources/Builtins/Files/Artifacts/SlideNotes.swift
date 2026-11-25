import Foundation

/// A slide's speaker notes in `slides.md`: a paragraph of the slide that starts with "Notes:", which the agent reads
/// and writes too. The page keeps it out of the slide and shows it under the slide, and never to the room.
enum SlideNotes {
    /// `source` with the slide that starts at line `line` (from 1) given `text` as its notes: its Notes line changed,
    /// added at the slide's end (before the rule that ends it), or taken away when `text` is empty.
    static func set(_ source: String, line: Int, text: String) -> String {
        var lines = source.components(separatedBy: "\n")
        let start = min(max(line - 1, 0), lines.count)
        let rule = { (i: Int) in
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return t.count >= 3 && Set(t).count == 1 && "-*_".contains(t.first ?? " ")
                && (i == 0 || lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let end = (start..<lines.count).first { $0 > start && rule($0) } ?? lines.count
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if let i = (start..<end).first(where: { lines[$0].hasPrefix("Notes:") }) {
            if !words.isEmpty {
                lines[i] = "Notes: " + words
            } else {
                lines.remove(at: i)
                if i > 0, lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: i - 1) }
            }
        } else if !words.isEmpty {
            var at = end
            while at > start, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(contentsOf: ["", "Notes: " + words], at: at)   // the blank lines before the rule stay
        }
        return lines.joined(separator: "\n")
    }
}
