import AppKit

/// The bars beside the line numbers, which show what differs from the last commit, as the file's tab tells it.
extension CodeEditor {
    public struct ChangeMark: Equatable, Sendable {
        public enum Kind: Sendable { case added, changed, removed }
        public let kind: Kind
        /// The line, 0-based. A removal sits on the line under the gap.
        public var line: Int
        /// How many lines the mark covers; 0 for a removal.
        public let count: Int
        public let hunk: Int
        public init(kind: Kind, line: Int, count: Int, hunk: Int) {
            self.kind = kind
            self.line = line
            self.count = count
            self.hunk = hunk
        }
        var lines: Range<Int> { line..<(line + max(count, 1)) }
    }

    /// The mark on 0-based line `line`, by binary search, because the gutter asks for every line it draws.
    func changeMark(onLine line: Int) -> ChangeMark? {
        let lo = changeMarks.partitionPoint { $0.line <= line }
        return lo > 0 && changeMarks[lo - 1].lines.contains(line) ? changeMarks[lo - 1] : nil
    }

    /// Called when lines came or went at `offset` (by typing, before the next save tells what really differs), so the
    /// marks under it stay beside their lines.
    func shiftChangeMarks(from offset: Int) {
        let delta = lineCount - markedLineCount
        guard delta != 0, !changeMarks.isEmpty else { return }
        let line = lineIndex.line(at: offset, in: textView.string as NSString)
        changeMarks = changeMarks.map { mark in
            var mark = mark
            if mark.line > line { mark.line = max(line, mark.line + delta) }
            return mark
        }
    }
}
