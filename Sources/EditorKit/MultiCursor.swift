import AppKit

/// The arrows (by character, word, line), Home, End and Esc with more than one cursor: each cursor moves, or with ⇧
/// each selection grows or shrinks at its moving end; Esc keeps the first. Other commands run for the first alone.
@MainActor enum MultiCursor {
    /// False for a command that isn't a move.
    static func move(_ tv: EditorTextView, _ command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) {
            tv.setCursors([tv.cursors[0]])
            return true
        }
        guard let (step, extend) = steps[command] else { return false }
        let s = tv.string as NSString, cs = tv.cursors
        guard extend else {
            // A plain move from a selection starts from its end on that side, as in VS Code.
            let forward = [Step.right, .wordRight, .down, .lineEnd].contains(step)
            tv.setCursors(cs.map { r in
                let at = forward ? NSMaxRange(r) : r.location
                let to = r.length > 0 && (step == .left || step == .right) ? at : target(step, from: at, in: s)
                return NSRange(location: to, length: 0)
            })
            return true
        }
        // ⇧: each selection keeps its anchor; the other end moves.
        let anchors = tv.anchors.count == cs.count ? tv.anchors : cs.map(\.location)
        var moved: [NSRange] = [], kept: [Int] = []
        for (r, a) in zip(cs, anchors) {
            let head = target(step, from: r.location == a ? NSMaxRange(r) : r.location, in: s)
            moved.append(NSRange(location: min(a, head), length: abs(head - a)))
            kept.append(a)
        }
        tv.setCursors(moved)
        tv.anchors = tv.cursors.count == kept.count ? kept : []   // merged selections: start again
        return true
    }

    enum Step { case left, right, wordLeft, wordRight, up, down, lineStart, lineEnd }

    private static let steps: [Selector: (Step, Bool)] = [
        #selector(NSResponder.moveLeft(_:)): (.left, false), #selector(NSResponder.moveBackward(_:)): (.left, false),
        #selector(NSResponder.moveRight(_:)): (.right, false), #selector(NSResponder.moveForward(_:)): (.right, false),
        #selector(NSResponder.moveWordLeft(_:)): (.wordLeft, false), #selector(NSResponder.moveWordBackward(_:)): (.wordLeft, false),
        #selector(NSResponder.moveWordRight(_:)): (.wordRight, false), #selector(NSResponder.moveWordForward(_:)): (.wordRight, false),
        #selector(NSResponder.moveUp(_:)): (.up, false), #selector(NSResponder.moveDown(_:)): (.down, false),
        #selector(NSResponder.moveToBeginningOfLine(_:)): (.lineStart, false), #selector(NSResponder.moveToLeftEndOfLine(_:)): (.lineStart, false),
        #selector(NSResponder.moveToBeginningOfParagraph(_:)): (.lineStart, false),
        #selector(NSResponder.moveToEndOfLine(_:)): (.lineEnd, false), #selector(NSResponder.moveToRightEndOfLine(_:)): (.lineEnd, false),
        #selector(NSResponder.moveToEndOfParagraph(_:)): (.lineEnd, false),
        #selector(NSResponder.moveLeftAndModifySelection(_:)): (.left, true), #selector(NSResponder.moveBackwardAndModifySelection(_:)): (.left, true),
        #selector(NSResponder.moveRightAndModifySelection(_:)): (.right, true),
        #selector(NSResponder.moveForwardAndModifySelection(_:)): (.right, true),
        #selector(NSResponder.moveWordLeftAndModifySelection(_:)): (.wordLeft, true),
        #selector(NSResponder.moveWordRightAndModifySelection(_:)): (.wordRight, true),
        #selector(NSResponder.moveUpAndModifySelection(_:)): (.up, true), #selector(NSResponder.moveDownAndModifySelection(_:)): (.down, true),
        #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)): (.lineEnd, true),
        #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)): (.lineEnd, true)
    ]

    static func target(_ step: Step, from i: Int, in s: NSString) -> Int {
        switch step {
        case .left: before(i, in: s)
        case .right: after(i, in: s)
        case .wordLeft: wordLeft(i, in: s)
        case .wordRight: wordRight(i, in: s)
        case .up: vertical(s, i, up: true)
        case .down: vertical(s, i, up: false)
        case .lineStart: s.lineRange(for: NSRange(location: i, length: 0)).location
        case .lineEnd: lineEnd(s, i)
        }
    }

    /// One character back or on (a composed one whole).
    static func before(_ i: Int, in s: NSString) -> Int { i > 0 ? s.rangeOfComposedCharacterSequence(at: i - 1).location : 0 }
    static func after(_ i: Int, in s: NSString) -> Int { i < s.length ? NSMaxRange(s.rangeOfComposedCharacterSequence(at: i)) : s.length }

    /// To the start of this or the previous word (⌥←), or the end of this or the next one (⌥→).
    static func wordLeft(_ i: Int, in s: NSString) -> Int {
        var j = i
        while j > 0, !isWord(s.character(at: j - 1)) { j -= 1 }
        while j > 0, isWord(s.character(at: j - 1)) { j -= 1 }
        return j
    }

    static func wordRight(_ i: Int, in s: NSString) -> Int {
        var j = i
        while j < s.length, !isWord(s.character(at: j)) { j += 1 }
        while j < s.length, isWord(s.character(at: j)) { j += 1 }
        return j
    }

    private static func isWord(_ c: unichar) -> Bool {
        UnicodeScalar(c).map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" } ?? true   // a surrogate half: part of a word
    }

    /// Where the line holding `i` ends, before its line break.
    nonisolated static func lineEnd(_ s: NSString, _ i: Int) -> Int {
        var end = 0, contentsEnd = 0
        s.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: i, length: 0))
        return contentsEnd
    }

    /// The same column a line up or down, or that line's end when it's shorter; the first or last line goes to its end.
    static func vertical(_ s: NSString, _ i: Int, up: Bool) -> Int {
        let line = s.lineRange(for: NSRange(location: i, length: 0)), column = i - line.location
        if up {
            guard line.location > 0 else { return 0 }
            let above = s.lineRange(for: NSRange(location: line.location - 1, length: 0))
            return min(above.location + column, lineEnd(s, above.location))
        }
        guard NSMaxRange(line) < s.length || Typing.lineBreak(s, line) > 0 else { return s.length }
        let below = NSMaxRange(line)
        return min(below + column, lineEnd(s, below))
    }
}
