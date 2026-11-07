import Foundation

/// A review page (`review.md`): numbered points, each with lettered options to pick one of, and a note. The file is
/// the record: a pick is `[x]` on its option, a note a `> Note:` line in its point, so the agent reads the answers there.
///
///     ## 1. Records that lose their implicit defaults
///     - [x] A. Write defaults into each init(from:) *recommended*
///       Nine small edits; decoding stays strict.
///     - [ ] B. A migration that fills the columns once
///     > Note: keep the old backups readable
public struct Review: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var key: String, text: String, detail: String, recommended: Bool, picked: Bool
    }
    public struct Point: Equatable, Sendable {
        public var number: String, question: String, options: [Option], note: String
        public var pick: String? { options.first { $0.picked }?.key }
    }

    public var title: String
    /// What comes between the title and the first point.
    public var intro: String
    public var points: [Point]

    public init(_ text: String) {
        title = ""
        intro = ""
        points = []
        var introLines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if title.isEmpty, points.isEmpty, let match = line.wholeMatch(of: /#\s+(.+)/) {
                title = String(match.1)
                continue
            }
            if let match = line.wholeMatch(of: Self.pointLine) {
                points.append(Point(number: String(match.1), question: String(match.2), options: [], note: ""))
                continue
            }
            guard !points.isEmpty else {
                introLines.append(line)
                continue
            }
            let last = points.count - 1
            if let match = line.wholeMatch(of: Self.optionLine) {
                var text = String(match.3)
                let recommended = text.contains("*recommended*")
                text = text.replacingOccurrences(of: "*recommended*", with: "").trimmingCharacters(in: .whitespaces)
                points[last].options.append(
                    Option(
                        key: String(match.2), text: text, detail: "", recommended: recommended, picked: match.1 != " "))
            } else if let match = line.wholeMatch(of: Self.noteLine) {
                points[last].note = String(match.1)
            } else if line.hasPrefix("  "), !points[last].options.isEmpty {
                let option = points[last].options.count - 1
                let detail = line.trimmingCharacters(in: .whitespaces)
                points[last].options[option].detail += (points[last].options[option].detail.isEmpty ? "" : " ") + detail
            }
        }
        intro = introLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` with `key` picked in point `number` (and its other options not).
    public static func pick(_ text: String, point number: String, option key: String) -> String {
        edit(text, point: number) { lines, range in
            for index in range {
                if let match = lines[index].wholeMatch(of: optionLine) {
                    lines[index] = "- [\(match.2 == key ? "x" : " ")] \(match.2). \(match.3)"
                }
            }
        }
    }

    /// `text` with point `number`'s note set to `note` (one line; empty takes it away).
    public static func note(_ text: String, point number: String, note: String) -> String {
        let one = note.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return edit(text, point: number) { lines, range in
            var range = range
            if let old = range.first(where: { lines[$0].wholeMatch(of: noteLine) != nil }) {
                lines.remove(at: old)
                range = range.lowerBound..<range.upperBound - 1
            }
            guard !one.isEmpty else { return }
            // After the point's last option (and its detail), before any blank line that ends the point.
            var at = range.lowerBound + 1
            for index in range
            where lines[index].wholeMatch(of: optionLine) != nil
                || (lines[index].hasPrefix("  ") && index > range.lowerBound)
            {
                at = index + 1
            }
            lines.insert("> Note: \(one)", at: at)
        }
    }

    /// The line that goes to the agent: "My answers in <file>: 1A 2B. Note on 2: …".
    public func answer(file: String) -> String {
        let picks = points.compactMap { p in p.pick.map { p.number + $0 } }
        let notes = points.filter { !$0.note.isEmpty }.map { "Note on \($0.number): \($0.note)" }
        return
            (["My answers in \(file): " + (picks.isEmpty ? "none picked" : picks.joined(separator: " ")) + "."]
            + notes.map { $0 + "." })
            .joined(separator: " ")
    }

    /// Whether `path` is a review Kelp made (`.kelp/artifacts/<name>/review.md`).
    public static func isReview(_ path: String) -> Bool {
        path.hasSuffix("/review.md") && path.contains("/\(Artifacts.folder)/")
    }

    // MARK: lines

    static var pointLine: Regex<(Substring, Substring, Substring)> { /##\s+(\d+)\.\s*(.+)/ }
    static var optionLine: Regex<(Substring, Substring, Substring, Substring)> { /- \[([ xX])\]\s+([A-Z])\.\s*(.*)/ }
    static var noteLine: Regex<(Substring, Substring)> { /\s*>\s*Note:\s*(.*)/ }

    /// Applies `change` to the lines of point `number` (its heading to the line before the next heading).
    private static func edit(_ text: String, point number: String, _ change: (inout [String], Range<Int>) -> Void)
        -> String
    {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.wholeMatch(of: pointLine)?.1 == Substring(number) }) else {
            return text
        }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
        change(&lines, start..<end)
        return lines.joined(separator: "\n")
    }
}
