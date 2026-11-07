import AppKit

extension CodeEditor {
    /// Where a wrapped line goes on (VS Code's `editor.wrappingIndent`).
    public enum WrappingIndent: String, Sendable {
        case none, same, indent
    }
}

/// A wrapped line's next rows start at the line's own indentation. Told here, row by row as lines are laid out, rather than as
/// a paragraph style per line: those would cost every line of a 5 MB file on opening, and on every edit that re-indents one.
final class WrappingContainer: NSTextContainer {
    /// What's on: the editor's say. While it's `none` or nothing wraps, the container is a plain rectangle, and the layout
    /// manager keeps its faster ways.
    var hanging = CodeEditor.WrappingIndent.none
    /// One space of the editor's font.
    var space: CGFloat = 8

    override var isSimpleRectangularTextContainer: Bool { hanging == .none }

    override func lineFragmentRect(forProposedRect proposed: NSRect, at index: Int, writingDirection: NSWritingDirection,
                                   remaining: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = super.lineFragmentRect(forProposedRect: proposed, at: index, writingDirection: writingDirection, remaining: remaining)
        guard hanging != .none, index > 0, let s = layoutManager?.textStorage?.string as NSString?, index <= s.length,
              s.character(at: index - 1) != 10 else { return rect }
        let line = lineStart(in: s, at: index - 1)
        let moved = min(indent(of: s, line: line), rect.width / 2)   // a deep line keeps some room
        rect.origin.x += moved
        rect.size.width -= moved
        return rect
    }

    /// A line's start and how far from it no line break was seen. Its rows are laid out one after another, and looking
    /// back to the start for each row of a 95k-character line was 79 ms a key; the editor forgets it on every edit (`edited`).
    private var known: (start: Int, through: Int)?
    func edited() { known = nil }

    private func lineStart(in s: NSString, at i: Int) -> Int {
        if let k = known, k.start <= i {
            if i <= k.through { return k.start }
            var j = k.through + 1
            while j <= i, s.character(at: j) != 10 { j += 1 }
            if j > i { known = (k.start, i); return k.start }
        }
        let start = s.lineRange(for: NSRange(location: i, length: 0)).location
        known = (start, i)
        return start
    }

    private func indent(of s: NSString, line start: Int) -> CGFloat {
        var columns = 0, i = start
        while i < s.length, i - start < 200 {
            let c = s.character(at: i)
            if c == 32 { columns += 1 } else if c == 9 { columns += 4 - columns % 4 } else { break }
            i += 1
        }
        return CGFloat(columns + (hanging == .indent ? 4 : 0)) * space
    }
}
