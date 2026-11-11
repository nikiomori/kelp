import Foundation

/// A review page (`review.md`): numbered points, each with lettered options to pick one of, and a note. The file is
/// the record: a pick is `[x]` on its option, a note a `> Note:` line in its point, so the agent reads the answers there.
///
///     ## 1. Records that lose their implicit defaults
///     - [x] A. Write defaults into each init(from:) *recommended*
///       Nine small edits; decoding stays strict.
///     - [ ] B. A migration that fills the columns once
///     > Note: keep the old backups readable
///
/// Once sent, a last line says when (`<!-- sent: 12:04 -->`); a point the agent has done ends its heading with ✓.
public struct Review: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var key: String, text: String, detail: String, recommended: Bool, picked: Bool
    }
    public struct Point: Equatable, Sendable {
        public var number: String, question: String, options: [Option], note: String
        /// The agent says it has done it: ✓ at the end of its heading.
        public var done = false
        public var pick: String? { options.first { $0.picked }?.key }
    }

    public var title: String
    /// What comes between the title and the first point.
    public var intro: String
    public var points: [Point]
    /// When the answers went to the agent (`<!-- sent: … -->`); nil until then, and again once a pick changes.
    public var sent: String?

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
            if let match = line.wholeMatch(of: Self.sentLine) {
                sent = String(match.1)
                continue
            }
            if let match = line.wholeMatch(of: Self.pointLine) {
                var question = String(match.2).trimmingCharacters(in: .whitespaces)
                let done = question.hasSuffix("✓")
                if done { question = String(question.dropLast()).trimmingCharacters(in: .whitespaces) }
                points.append(Point(number: String(match.1), question: question, options: [], note: "", done: done))
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

    /// `text` with `key` picked in point `number` (and its other options not): answers not sent yet.
    public static func pick(_ text: String, point number: String, option key: String) -> String {
        edit(unsent(text), point: number) { lines, range in
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
        return edit(unsent(text), point: number) { lines, range in
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

    /// `text` with the recommended option picked in each point that has no pick yet.
    public static func pickRecommended(_ text: String) -> String {
        Review(text).points.reduce(text) { text, point in
            guard point.pick == nil, let key = point.options.first(where: \.recommended)?.key else { return text }
            return pick(text, point: point.number, option: key)
        }
    }

    /// `text` saying its answers went to the agent at `time`.
    public static func markSent(_ text: String, at time: String) -> String {
        var out = unsent(text)
        while out.hasSuffix("\n\n") { out.removeLast() }
        return out + (out.hasSuffix("\n") ? "" : "\n") + "\n<!-- sent: \(time) -->\n"
    }

    /// `text` without the line saying when its answers were sent.
    public static func unsent(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { $0.wholeMatch(of: sentLine) != nil }) else { return text }
        return lines.filter { $0.wholeMatch(of: sentLine) == nil }.joined(separator: "\n")
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
    static var sentLine: Regex<(Substring, Substring)> { /<!--\s*sent:\s*(.*?)\s*-->/ }
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
