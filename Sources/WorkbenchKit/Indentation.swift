import Foundation

/// How a file is indented, as the editor's status bar says it: tabs, or spaces in steps of `n`.
public enum Indentation: Equatable, Sendable {
    case tabs, spaces(Int)

    /// Read from the file's first lines: tabs if most indented lines start with one; else the widest step (8, 4, 3, 2)
    /// that nine in ten of the indented lines are a multiple of. Nil when nothing is indented.
    public static func detect(_ text: String) -> Indentation? {
        var tabs = 0, widths: [Int] = [], lines = 0
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
            if n > 0, n < line.count { widths.append(n) }
        }
        if tabs > widths.count { return .tabs }
        guard !widths.isEmpty else { return nil }
        let step = [8, 4, 3, 2].first { s in Double(widths.filter { $0 % s == 0 }.count) >= 0.9 * Double(widths.count) } ?? 1
        return .spaces(step)
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
