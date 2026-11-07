import AppKit
@preconcurrency import SwiftTreeSitter

/// The bracket next to the cursor and its partner, marked: found in the parse tree, so a bracket in a string or a
/// comment isn't one; by counting in a file without a grammar.
enum Brackets {
    private static let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]   // () [] {}
    /// Tree-sitter finds a child by walking its siblings: an array this long took a stall per cursor move (400k: 230 ms).
    private static let maxChildren: UInt32 = 10_000

    /// Where the bracket at `at` closes or opens; nil when it isn't one, or has none.
    static func partner(of at: Int, in string: NSString, tree: Tree?) -> Int? {
        let bracket = string.character(at: at)
        let opens = pairs[bracket] != nil
        guard let other = pairs[bracket] ?? pairs.first(where: { $0.value == bracket })?.key else { return nil }
        guard let root = tree?.rootNode else { return count(from: at, opens: opens, bracket, other, in: string) }
        // The bracket's own token, and the same bracket on the other side among its siblings.
        guard let node = root.descendant(in: UInt32(at * 2)..<UInt32(at * 2 + 2)),
            node.range == NSRange(location: at, length: 1),
            let parent = node.parent, parent.childCount <= maxChildren
        else { return nil }
        let kids = (0..<parent.childCount).compactMap { parent.child(at: $0) }
        guard let own = kids.firstIndex(where: { $0.range == node.range }) else { return nil }
        let side = opens ? Array(kids[(own + 1)...]) : Array(kids[..<own].reversed())
        let hit = side.first {
            $0.range.length == 1 && NSMaxRange($0.range) <= string.length
                && string.character(at: $0.range.location) == other
        }
        return hit?.range.location
    }

    /// Without a tree: the matching one by nesting, within 100k characters.
    private static func count(from at: Int, opens: Bool, _ bracket: unichar, _ other: unichar, in string: NSString)
        -> Int?
    {
        var depth = 0, index = at
        let end = opens ? min(string.length, at + 100_000) : max(-1, at - 100_000)
        while index != end {
            let ch = string.character(at: index)
            if ch == bracket {
                depth += 1
            } else if ch == other {
                depth -= 1
                if depth == 0 { return index }
            }
            index += opens ? 1 : -1
        }
        return nil
    }
}

extension CodeEditor {
    /// Marks the bracket just before the cursor (else just after) and its partner, when there's one cursor.
    func markBrackets() {
        guard let lm = textView.layoutManager else { return }
        let string = textView.string as NSString
        // Only the marks: over the whole text this walks every color in it (160 ms per cursor move in a 5 MB file).
        for mark in marked where NSMaxRange(mark) <= string.length {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: mark)
        }
        marked = []
        let selection = textView.selectedRange()
        guard textView.cursors.count == 1, selection.length == 0 else { return }
        for at in [selection.location - 1, selection.location] where at >= 0 && at < string.length {
            guard let partner = Brackets.partner(of: at, in: string, tree: highlighter?.tree) else { continue }
            marked = [at, partner].map { NSRange(location: $0, length: 1) }
            for mark in marked {
                lm.addTemporaryAttribute(.backgroundColor, value: bracketColor, forCharacterRange: mark)
            }
            return
        }
    }

    /// A mark after `edit` is replaced by `length` characters: the text carries it along; nil when the text under it went.
    static func moved(_ mark: NSRange, by edit: NSRange, to length: Int) -> NSRange? {
        if mark.location >= NSMaxRange(edit) {
            return NSRange(location: mark.location + length - edit.length, length: mark.length)
        }
        return NSMaxRange(mark) <= edit.location ? mark : length > 0 ? NSRange(location: edit.location, length: 1) : nil
    }
}
