import Core
import Foundation

public enum TextEdits {
    /// A server's edits to `text`, positions in UTF-16 units of the text as it was. Applied last first, so none moves another.
    public static func applied(_ edits: [CodeEdit], to text: String) -> String {
        let s = NSMutableString(string: text)
        var starts = [0]
        for i in 0..<s.length where s.character(at: i) == 10 { starts.append(i + 1) }
        func offset(_ line: Int, _ column: Int) -> Int { line < starts.count ? min(starts[line] + column, s.length) : s.length }
        let spans = edits.map { (from: offset($0.line, $0.column), to: offset($0.endLine, $0.endColumn), text: $0.text) }
        for e in spans.sorted(by: { $0.from > $1.from }) {
            s.replaceCharacters(in: NSRange(location: e.from, length: max(e.to - e.from, 0)), with: e.text)
        }
        return s as String
    }
}
