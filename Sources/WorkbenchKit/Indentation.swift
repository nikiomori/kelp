import Foundation

/// How a file is indented, as the editor's status bar says it: tabs, or spaces in steps of `n`.
public enum Indentation: Equatable, Sendable {
    case tabs, spaces(Int)

    /// Read from the file's first lines: tabs if most indented lines start with one; else the step the indent most often
    /// moves by from one line to the next, the smaller of two as common, not how deep most lines are (a long function's body
    /// all at 8 is still indented by 4). Nil when nothing is indented.
    public static func detect(_ text: String) -> Indentation? {
        var tabs = 0, indented = 0, lines = 0, last = 0, steps: [Int: Int] = [:]
        // Bytes, stopping at the 2000th line: splitting all of a 5 MB file into Characters took 80 ms of main thread.
        let b = text.utf8
        var i = b.startIndex
        while i < b.endIndex, lines < 2000 {
            let end = b[i...].firstIndex { (10...13).contains($0) } ?? b.endIndex   // \n, \r (\r\n leaves an empty line), VT, FF
            let line = b[i..<end]
            i = end < b.endIndex ? b.index(after: end) : end
            guard !line.isEmpty else { continue }
            lines += 1
            if line.first == 9 { tabs += 1; continue }
            let n = line.prefix { $0 == 32 }.count
            guard n < line.count else { continue }   // only spaces: says nothing
            if n > 0 { indented += 1 }
            if [2, 3, 4, 8].contains(abs(n - last)) { steps[abs(n - last), default: 0] += 1 }
            last = n
        }
        if tabs > indented { return .tabs }
        guard indented > 0 else { return nil }
        let best = steps.max { ($0.value, -$0.key) < ($1.value, -$1.key) }
        return .spaces(best?.key ?? 4)
    }

    /// `text` with each line's leading whitespace in this indentation, the same depth with `tabSize` columns to a level.
    public func applied(to text: String, tabSize: Int) -> String {
        text.components(separatedBy: "\n").map { line -> String in   // not split(): "\r\n" is one Character to it
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let columns = lead.reduce(0) { $1 == "\t" ? $0 + tabSize - $0 % tabSize : $0 + 1 }
            let indent: String
            switch self {
            case .tabs: indent = String(repeating: "\t", count: columns / tabSize) + String(repeating: " ", count: columns % tabSize)
            case .spaces: indent = String(repeating: " ", count: columns)
            }
            return indent + line.dropFirst(lead.count)
        }.joined(separator: "\n")
    }

    /// What Save tidies: spaces and tabs at line ends, and a last line without a newline.
    public static func cleaned(_ text: String, trim: Bool, finalNewline: Bool) -> String {
        var out = !trim ? text : text.components(separatedBy: "\n").map { line -> String in
            var l = Substring(line)
            let cr = l.last == "\r"
            if cr { l = l.dropLast() }
            while l.last == " " || l.last == "\t" { l = l.dropLast() }
            return cr ? l + "\r" : String(l)
        }.joined(separator: "\n")
        if finalNewline, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        return out
    }
}
