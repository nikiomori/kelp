import Agents
import Core
import Foundation

/// Finds text in what a session printed, for ⌘P (`SessionFind`). It matches the way the terminal's own find does
/// (Ghostty folds the case of ASCII letters only), so the line ⌘P shows is one the terminal's find lands on.
enum OutputSearch {
    /// The newest line of `text` holding `query`, cut to the part around it, and how many lines hold it; nil when none
    /// does. A carriage return alone starts a line too, because a program redraws its line with one ("\r\n" is one
    /// character in Swift, so a line is split at any newline character, not at "\n" and "\r").
    static func newest(_ query: String, in text: String) -> (line: String, count: Int)? {
        let needle = folded(query)
        guard !needle.isEmpty else { return nil }
        var newest: Substring?, count = 0
        for line in text.split(whereSeparator: \.isNewline) where folded(line).contains(needle) {
            newest = line
            count += 1
        }
        return newest.map { (around(needle, in: String($0)), count) }
    }

    /// The line without blanks at its ends, and from a little before the match when the match is far in, so a row cut
    /// at its end still shows it. At most 200 characters.
    static func around(_ needle: String, in line: String) -> String {
        let line = line.trimmingCharacters(in: .whitespaces), lower = folded(line)
        guard let match = lower.range(of: needle) else { return String(line.prefix(200)) }
        let start = lower.distance(from: lower.startIndex, to: match.lowerBound)
        return start > 60 ? "…" + line.dropFirst(start - 20).prefix(200) : String(line.prefix(200))
    }

    /// Lowercases ASCII letters and leaves every other character as it is, as Ghostty compares.
    static func folded(_ text: some StringProtocol) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32) ?? $0 : $0 }))
    }
}

/// Reads each running session's kept output whole (a megabyte at most), on `offload`'s threads like any method that
/// isn't quick. A paused session isn't woken for it.
extension SessionFind: Handled {
    func handle(_ live: SessionTable) throws -> [SessionFound] {
        ids.compactMap { id in
            guard let ls = live[id] else { return nil }
            // swiftlint:disable:next optional_data_string_conversion
            let text = StatusDetector.stripANSI(String(decoding: ls.tail(LiveSession.ringLimit), as: UTF8.self))
            return OutputSearch.newest(query, in: text).map { SessionFound(id: id, line: $0.line, count: $0.count) }
        }
    }
}
