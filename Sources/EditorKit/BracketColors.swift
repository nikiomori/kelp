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

    func colorBrackets(_ range: NSRange, in string: NSString, _ lm: NSLayoutManager) {
        guard !bracketColors.isEmpty, let tree, let root = tree.rootNode, let bracketQuery else { return }
        let cursor = bracketQuery.execute(node: root, in: tree)
        cursor.setRange(range)
        var found: [NSRange] = []
        while let match = cursor.next() { found += match.captures.map(\.range) }
        var depth = Self.depth(before: range.location, in: string, under: root)
        for bracket in found.sorted(by: { $0.location < $1.location }) where NSLocationInRange(bracket.location, range)
        {
            let opens = Self.opens(string.character(at: bracket.location))
            if !opens { depth = max(depth - 1, 0) }
            lm.addTemporaryAttribute(
                .foregroundColor, value: bracketColors[depth % bracketColors.count], forCharacterRange: bracket)
            if opens { depth += 1 }
        }
    }

    private static func opens(_ character: unichar) -> Bool { character == 40 || character == 91 || character == 123 }

    /// The brackets still open at `at`: down the tree to it, counting the ones left of the way (those inside a sibling match).
    private static func depth(before at: Int, in string: NSString, under root: Node) -> Int {
        var node = root, depth = 0
        while node.childCount <= mostSiblings {
            var inside: Node?
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                let childRange = child.range
                if childRange.location >= at { break }
                if NSMaxRange(childRange) > at {
                    inside = child
                    break
                }
                if childRange.length == 1,
                    [40, 91, 123, 41, 93, 125].contains(string.character(at: childRange.location))
                {
                    depth += opens(string.character(at: childRange.location)) ? 1 : -1
                }
            }
            guard let inside else { break }
            node = inside
        }
        return max(depth, 0)
    }
}
