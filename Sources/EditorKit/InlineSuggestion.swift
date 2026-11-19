import Foundation

/// Gray text after the cursor that ⇥ puts in: what a model offers given the code before and after the cursor. The
/// editor asks the app for it (`CodeEditor.suggestionProvider`); this is the text logic around that, kept apart from
/// AppKit so it can be tested.
public enum InlineSuggestion {
    /// What the app gets to ask a model with.
    public struct Context: Sendable, Equatable {
        public let prefix: String
        public let suffix: String
        public let languageId: String
        public let path: String
    }

    /// How much text around the cursor goes to the model, in UTF-16 units: about 1500 and 500 tokens of code. The
    /// start of what goes before it moves in steps of `windowStep` (`windowStart`).
    static let prefixLimit = 6000, suffixLimit = 2000, windowStep = 1500
    /// The most lines a suggestion shows.
    static let lineLimit = 12
    private static let closers = Set(")]}>\"'`;,")

    /// Where the code sent before the cursor at `location` starts: about `prefixLimit` back, moved down to a step of
    /// `windowStep` and then to the start of its line. It stays put while you type, so the model's server reuses what
    /// it read (measured: 711 → 207 ms a suggestion, a window that slid with each key made it read it all again).
    static func windowStart(at location: Int, in string: NSString) -> Int {
        let back = location - prefixLimit
        guard back > 0 else { return 0 }
        return string.lineRange(for: NSRange(location: back / windowStep * windowStep, length: 0)).location
    }

    /// Where the code sent after the cursor at `location` ends: about `suffixLimit` on, moved up to a step of
    /// `windowStep` and then to the end of its line. A model asked suffix first (Seed-Coder) reads it before the code
    /// above the cursor, so an end that moved with each key had it read everything again (measured: 3.7 → 0.35 s for
    /// the slowest tenth of suggestions).
    static func windowEnd(at location: Int, in string: NSString) -> Int {
        let forward = location + suffixLimit
        guard forward < string.length else { return string.length }
        let snapped = (forward + windowStep - 1) / windowStep * windowStep
        guard snapped < string.length else { return string.length }
        return NSMaxRange(string.lineRange(for: NSRange(location: snapped, length: 0)))
    }

    /// Whether the rest of the line after the cursor leaves room for a suggestion: nothing, or only what closes a
    /// bracket or a string (an auto-paired `)`), which the gray text then goes in front of.
    static func fits(beforeRest rest: Substring) -> Bool {
        rest.allSatisfy { $0 == " " || $0 == "\t" || closers.contains($0) }
    }

    /// What a model's raw answer shows as, or nil when nothing is worth showing. It ends with the block the cursor is
    /// in: before an empty line or a line indented less than the cursor's (`indent`, in characters) that doesn't only
    /// close brackets, and before a line repeating the next line already below the cursor, so ⇥ never doubles a `}`.
    /// It loses what the rest of the line already holds, and stops after `lineLimit` lines.
    static func cleaned(_ raw: String, rest: Substring, below: String, indent: Int = 0) -> String? {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let end = lines.indices.dropFirst().first(where: { index in
            let line = lines[index], code = line.drop { $0 == " " || $0 == "\t" }
            return line.isEmpty
                || !code.isEmpty && line.count - code.count < indent && !code.allSatisfy({ closers.contains($0) })
        }) {
            lines.removeSubrange(end...)
        }
        // Split on "\n" in UTF-16: a Character split keeps "\r\n" whole, and a CRLF file would be one line.
        let next = below.components(separatedBy: "\n").first { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let next,
            let cut = lines.indices.dropFirst().first(where: {
                lines[$0].trimmingCharacters(in: .whitespaces) == next
            })
        {
            lines.removeSubrange(cut...)
        }
        lines = Array(lines.prefix(lineLimit))
        let tail = rest.trimmingCharacters(in: .whitespaces)
        // A last line of spaces puts the line's closers on a line of their own, indented; with none it's only trailing.
        while lines.count > 1, let last = lines.last, last.isEmpty || tail.isEmpty && last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }
        var text = lines.joined(separator: "\n")
        if !tail.isEmpty, text.hasSuffix(tail) { text.removeLast(tail.count) }
        // Spaces before a closer stay (`{ a }`); at the end of the line they would only be trailing.
        while tail.isEmpty, text.last == " " || text.last == "\t" { text.removeLast() }
        return text.allSatisfy(\.isWhitespace) ? nil : text
    }

    /// How far the last line of `text` is indented, in characters (CRLF too: see `cleaned`).
    static func indent(of text: String) -> Int {
        (text.components(separatedBy: "\n").last ?? "").prefix { $0 == " " || $0 == "\t" }.count
    }

    /// What's left of `shown` once `typed` went in at its start, or nil when the typing went another way.
    static func remaining(_ shown: String, after typed: String) -> String? {
        guard !typed.isEmpty, shown.hasPrefix(typed), shown.count > typed.count else { return nil }
        return String(shown.dropFirst(typed.count))
    }

    /// The part ⌥→ takes: spaces, then a word, or a single other character.
    static func nextWord(of shown: String) -> String {
        let spaces = shown.prefix { $0 == " " || $0 == "\t" }
        let rest = shown.dropFirst(spaces.count)
        let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return String(spaces) + (word.isEmpty ? String(rest.prefix(1)) : String(word))
    }
}
