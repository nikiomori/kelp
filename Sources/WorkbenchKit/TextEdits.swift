import Core
import Foundation

public enum TextEdits {
    /// A server's edits to `text`, positions in UTF-16 units of the text as it was. Applied last first, so none moves another.
    public static func applied(_ edits: [CodeEdit], to text: String) -> String {
        let buffer = NSMutableString(string: text)
        var starts = [0]
        for i in 0..<buffer.length where buffer.character(at: i) == 10 { starts.append(i + 1) }
        func offset(_ line: Int, _ column: Int) -> Int {
            line < starts.count ? min(starts[line] + column, buffer.length) : buffer.length
        }
        let spans = edits.map {
            (from: offset($0.line, $0.column), to: offset($0.endLine, $0.endColumn), text: $0.text)
        }
        for e in spans.sorted(by: { $0.from > $1.from }) {
            buffer.replaceCharacters(in: NSRange(location: e.from, length: max(e.to - e.from, 0)), with: e.text)
        }
        return buffer as String
    }

    /// `text` with 1-based line `n` now `new`; nil when that line isn't `expected` any more (an agent changed the file since
    /// it was shown). What ends the line stays.
    public static func replacing(line n: Int, expected: String, with new: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(n - 1) else { return nil }
        let carriage = lines[n - 1].hasSuffix("\r"), old = carriage ? String(lines[n - 1].dropLast()) : lines[n - 1]
        guard old == expected else { return nil }
        lines[n - 1] = new + (carriage ? "\r" : "")
        return lines.joined(separator: "\n")
    }
}
