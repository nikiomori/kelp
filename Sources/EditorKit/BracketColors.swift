import AppKit
@preconcurrency import SwiftTreeSitter

/// Brackets coloured by how deep they sit. Only the grammar's bracket tokens count, so one in a string or a comment isn't
/// one, whether or not the grammar's highlights name them; and the depth where the colouring starts comes from the tree,
/// so a colour doesn't change with the scroll position.
extension SyntaxHighlighter {
    /// Past this many siblings a list's own brackets aren't counted: reaching a child walks the ones before it.
    private static let mostSiblings: UInt32 = 2_000

    /// A grammar without one of the tokens refuses the query, so each is tried alone.
    static func bracketQuery(_ language: Language) -> Query? {
        let tokens = ["(", ")", "[", "]", "{", "}"].map { "\"\($0)\" @bracket" }.filter { pattern in
            (try? Query(language: language, data: Data(pattern.utf8))) != nil
        }
        return try? Query(language: language, data: Data(tokens.joined(separator: "\n").utf8))
    }

    func colorBrackets(_ range: NSRange, in s: NSString, _ lm: NSLayoutManager) {
        guard !bracketColors.isEmpty, let tree, let root = tree.rootNode, let bracketQuery else { return }
        let cursor = bracketQuery.execute(node: root, in: tree)
        cursor.setRange(range)
        var found: [NSRange] = []
        while let m = cursor.next() { found += m.captures.map(\.range) }
        var depth = Self.depth(before: range.location, in: s, under: root)
        for r in found.sorted(by: { $0.location < $1.location }) where NSLocationInRange(r.location, range) {
            let opens = Self.opens(s.character(at: r.location))
            if !opens { depth = max(depth - 1, 0) }
            lm.addTemporaryAttribute(.foregroundColor, value: bracketColors[depth % bracketColors.count], forCharacterRange: r)
            if opens { depth += 1 }
        }
    }

    private static func opens(_ c: unichar) -> Bool { c == 40 || c == 91 || c == 123 }

    /// The brackets still open at `at`: down the tree to it, counting the ones left of the way (those inside a sibling match).
    private static func depth(before at: Int, in s: NSString, under root: Node) -> Int {
        var node = root, depth = 0
        while node.childCount <= mostSiblings {
            var inside: Node?
            for i in 0..<node.childCount {
                guard let c = node.child(at: i) else { continue }
                let r = c.range
                if r.location >= at { break }
                if NSMaxRange(r) > at {
                    inside = c
                    break
                }
                if r.length == 1, [40, 91, 123, 41, 93, 125].contains(s.character(at: r.location)) { depth += opens(s.character(at: r.location)) ? 1 : -1 }
            }
            guard let inside else { break }
            node = inside
        }
        return max(depth, 0)
    }
}
