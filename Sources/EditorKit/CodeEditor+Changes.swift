import AppKit

/// The bars beside the line numbers: what differs from the last commit, told by the file's tab.
extension CodeEditor {
    public struct ChangeMark: Equatable, Sendable {
        public enum Kind: Sendable { case added, changed, removed }
        public let kind: Kind
        /// 0-based; a removal sits on the line under the gap.
        public var line: Int
        /// 0 for a removal.
        public let count: Int
        public let hunk: Int
        public init(kind: Kind, line: Int, count: Int, hunk: Int) { self.kind = kind; self.line = line; self.count = count; self.hunk = hunk }
        var lines: Range<Int> { line..<(line + max(count, 1)) }
    }

    /// The mark on 0-based line `n`, by binary search: the gutter asks for every line it draws.
    func changeMark(onLine n: Int) -> ChangeMark? {
        var lo = 0, hi = changeMarks.count
        while lo < hi { let mid = (lo + hi) / 2; if changeMarks[mid].line <= n { lo = mid + 1 } else { hi = mid } }
        return lo > 0 && changeMarks[lo - 1].lines.contains(n) ? changeMarks[lo - 1] : nil
    }

    /// Lines came or went at `offset` (typing, before the next save tells what really differs): the marks under it stay
    /// beside their lines.
    func shiftChangeMarks(from offset: Int) {
        let delta = lineCount - markedLineCount
        guard delta != 0, !changeMarks.isEmpty else { return }
        let line = lineIndex.line(at: offset, in: textView.string as NSString)
        changeMarks = changeMarks.map { m in
            var m = m
            if m.line > line { m.line = max(line, m.line + delta) }
            return m
        }
    }
}
