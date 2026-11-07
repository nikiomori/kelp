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

    override func lineFragmentRect(
        forProposedRect proposed: NSRect, at index: Int, writingDirection: NSWritingDirection,
        remaining: UnsafeMutablePointer<NSRect>?
    ) -> NSRect {
        var rect = super.lineFragmentRect(
            forProposedRect: proposed, at: index, writingDirection: writingDirection, remaining: remaining)
        guard hanging != .none, index > 0, let string = layoutManager?.textStorage?.string as NSString?,
            index <= string.length,
            string.character(at: index - 1) != 10
        else { return rect }
        let line = lineStart(in: string, at: index - 1)
        let moved = min(indent(of: string, line: line), rect.width / 2)   // a deep line keeps some room
        rect.origin.x += moved
        rect.size.width -= moved
        return rect
    }

    /// A line's start and how far from it no line break was seen. Its rows are laid out one after another, and looking
    /// back to the start for each row of a 95k-character line was 79 ms a key; the editor forgets it on every edit (`edited`).
    private var known: (start: Int, through: Int)?
    func edited() { known = nil }

    private func lineStart(in string: NSString, at index: Int) -> Int {
        if let cached = known, cached.start <= index {
            if index <= cached.through { return cached.start }
            var scan = cached.through + 1
            while scan <= index, string.character(at: scan) != 10 { scan += 1 }
            if scan > index {
                known = (cached.start, index)
                return cached.start
            }
        }
        let start = string.lineRange(for: NSRange(location: index, length: 0)).location
        known = (start, index)
        return start
    }

    private func indent(of string: NSString, line start: Int) -> CGFloat {
        var columns = 0, index = start
        while index < string.length, index - start < 200 {
            let character = string.character(at: index)
            if character == 32 { columns += 1 } else if character == 9 { columns += 4 - columns % 4 } else { break }
            index += 1
        }
        return CGFloat(columns + (hanging == .indent ? 4 : 0)) * space
    }
}
