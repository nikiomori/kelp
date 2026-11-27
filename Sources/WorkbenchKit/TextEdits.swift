import Core
import Foundation

public enum TextEdits {
    /// Applies a server's edits to `text`, with positions in UTF-16 units of the text as it was. The edits are applied
    /// last first, so no edit moves another.
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
        for edit in spans.sorted(by: { $0.from > $1.from }) {
            buffer.replaceCharacters(
                in: NSRange(location: edit.from, length: max(edit.to - edit.from, 0)), with: edit.text)
        }
        return buffer as String
    }

    /// Returns `text` with 1-based line `n` replaced by `new`, or nil when that line isn't `expected` any more (an
    /// agent changed the file since it was shown). The line's ending stays as it was.
    public static func replacing(line number: Int, expected: String, with new: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(number - 1) else { return nil }
        let carriage = lines[number - 1].hasSuffix("\r"),
            old = carriage ? String(lines[number - 1].dropLast()) : lines[number - 1]
        guard old == expected else { return nil }
        lines[number - 1] = new + (carriage ? "\r" : "")
        return lines.joined(separator: "\n")
    }
}
