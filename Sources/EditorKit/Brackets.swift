import AppKit
@preconcurrency import SwiftTreeSitter

/// The bracket next to the cursor and its partner, marked: found in the parse tree, so a bracket in a string or a
/// comment isn't one; by counting in a file without a grammar.
enum Brackets {
    private static let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]   // () [] {}

    /// Where the bracket at `at` closes or opens; nil when it isn't one, or has none.
    static func partner(of at: Int, in s: NSString, tree: Tree?) -> Int? {
        let c = s.character(at: at)
        let opens = pairs[c] != nil
        guard let other = pairs[c] ?? pairs.first(where: { $0.value == c })?.key else { return nil }
        guard let root = tree?.rootNode else { return count(from: at, opens: opens, c, other, in: s) }
        // The bracket's own token, and the same bracket on the other side among its siblings.
        guard let node = root.descendant(in: UInt32(at * 2)..<UInt32(at * 2 + 2)), node.range == NSRange(location: at, length: 1),
              let parent = node.parent else { return nil }
        let kids = (0..<parent.childCount).compactMap { parent.child(at: $0) }
        guard let k = kids.firstIndex(where: { $0.range == node.range }) else { return nil }
        let side = opens ? Array(kids[(k + 1)...]) : Array(kids[..<k].reversed())
        let hit = side.first { $0.range.length == 1 && NSMaxRange($0.range) <= s.length && s.character(at: $0.range.location) == other }
        return hit?.range.location
    }

    /// Without a tree: the matching one by nesting, within 100k characters.
    private static func count(from at: Int, opens: Bool, _ c: unichar, _ other: unichar, in s: NSString) -> Int? {
        var depth = 0, i = at
        let end = opens ? min(s.length, at + 100_000) : max(-1, at - 100_000)
        while i != end {
            let ch = s.character(at: i)
            if ch == c { depth += 1 } else if ch == other { depth -= 1; if depth == 0 { return i } }
            i += opens ? 1 : -1
        }
        return nil
    }
}

extension CodeEditor {
    /// Marks the bracket just before the cursor (else just after) and its partner, when there's one cursor.
    func markBrackets() {
        guard let lm = textView.layoutManager else { return }
        let s = textView.string as NSString
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: s.length))
        let r = textView.selectedRange()
        guard textView.cursors.count == 1, r.length == 0 else { return }
        for at in [r.location - 1, r.location] where at >= 0 && at < s.length {
            guard let p = Brackets.partner(of: at, in: s, tree: highlighter?.tree) else { continue }
            for i in [at, p] { lm.addTemporaryAttribute(.backgroundColor, value: bracketColor, forCharacterRange: NSRange(location: i, length: 1)) }
            return
        }
    }
}
