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
        let string = tv.string as NSString, cs = tv.cursors
        guard extend else {
            // A plain move from a selection starts from its end on that side, as in VS Code.
            let forward = [Step.right, .wordRight, .down, .lineEnd].contains(step)
            tv.setCursors(
                cs.map { cursor in
                    let at = forward ? NSMaxRange(cursor) : cursor.location
                    let to =
                        cursor.length > 0 && (step == .left || step == .right) ? at : target(step, from: at, in: string)
                    return NSRange(location: to, length: 0)
                })
            return true
        }
        // ⇧: each selection keeps its anchor; the other end moves.
        let anchors = tv.anchors.count == cs.count ? tv.anchors : cs.map(\.location)
        var moved: [NSRange] = [], kept: [Int] = []
        for (selection, anchor) in zip(cs, anchors) {
            let head = target(
                step, from: selection.location == anchor ? NSMaxRange(selection) : selection.location, in: string)
            moved.append(NSRange(location: min(anchor, head), length: abs(head - anchor)))
            kept.append(anchor)
        }
        tv.setCursors(moved)
        tv.anchors = tv.cursors.count == kept.count ? kept : []   // merged selections: start again
        return true
    }

    enum Step { case left, right, wordLeft, wordRight, up, down, lineStart, lineEnd }

    private static let steps: [Selector: (Step, Bool)] = [
        #selector(NSResponder.moveLeft(_:)): (.left, false), #selector(NSResponder.moveBackward(_:)): (.left, false),
        #selector(NSResponder.moveRight(_:)): (.right, false), #selector(NSResponder.moveForward(_:)): (.right, false),
        #selector(NSResponder.moveWordLeft(_:)): (.wordLeft, false),
        #selector(NSResponder.moveWordBackward(_:)): (.wordLeft, false),
        #selector(NSResponder.moveWordRight(_:)): (.wordRight, false),
        #selector(NSResponder.moveWordForward(_:)): (.wordRight, false),
        #selector(NSResponder.moveUp(_:)): (.up, false), #selector(NSResponder.moveDown(_:)): (.down, false),
        #selector(NSResponder.moveToBeginningOfLine(_:)): (.lineStart, false),
        #selector(NSResponder.moveToLeftEndOfLine(_:)): (.lineStart, false),
        #selector(NSResponder.moveToBeginningOfParagraph(_:)): (.lineStart, false),
        #selector(NSResponder.moveToEndOfLine(_:)): (.lineEnd, false),
        #selector(NSResponder.moveToRightEndOfLine(_:)): (.lineEnd, false),
        #selector(NSResponder.moveToEndOfParagraph(_:)): (.lineEnd, false),
        #selector(NSResponder.moveLeftAndModifySelection(_:)): (.left, true),
        #selector(NSResponder.moveBackwardAndModifySelection(_:)): (.left, true),
        #selector(NSResponder.moveRightAndModifySelection(_:)): (.right, true),
        #selector(NSResponder.moveForwardAndModifySelection(_:)): (.right, true),
        #selector(NSResponder.moveWordLeftAndModifySelection(_:)): (.wordLeft, true),
        #selector(NSResponder.moveWordRightAndModifySelection(_:)): (.wordRight, true),
        #selector(NSResponder.moveUpAndModifySelection(_:)): (.up, true),
        #selector(NSResponder.moveDownAndModifySelection(_:)): (.down, true),
        #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)): (.lineEnd, true),
        #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)): (.lineEnd, true)
    ]

    static func target(_ step: Step, from location: Int, in string: NSString) -> Int {
        switch step {
        case .left: before(location, in: string)
        case .right: after(location, in: string)
        case .wordLeft: wordLeft(location, in: string)
        case .wordRight: wordRight(location, in: string)
        case .up: vertical(string, location, up: true)
        case .down: vertical(string, location, up: false)
        case .lineStart: string.lineRange(for: NSRange(location: location, length: 0)).location
        case .lineEnd: lineEnd(string, location)
        }
    }

    /// One character back or on (a composed one whole).
    static func before(_ location: Int, in string: NSString) -> Int {
        location > 0 ? string.rangeOfComposedCharacterSequence(at: location - 1).location : 0
    }
    static func after(_ location: Int, in string: NSString) -> Int {
        location < string.length ? NSMaxRange(string.rangeOfComposedCharacterSequence(at: location)) : string.length
    }

    /// To the start of this or the previous word (⌥←), or the end of this or the next one (⌥→).
    static func wordLeft(_ location: Int, in string: NSString) -> Int {
        var scan = location
        while scan > 0, !isWord(string.character(at: scan - 1)) { scan -= 1 }
        while scan > 0, isWord(string.character(at: scan - 1)) { scan -= 1 }
        return scan
    }

    static func wordRight(_ location: Int, in string: NSString) -> Int {
        var scan = location
        while scan < string.length, !isWord(string.character(at: scan)) { scan += 1 }
        while scan < string.length, isWord(string.character(at: scan)) { scan += 1 }
        return scan
    }

    private static func isWord(_ character: unichar) -> Bool {
        UnicodeScalar(character).map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" } ?? true   // a surrogate half: part of a word
    }

    /// Where the line holding `location` ends, before its line break.
    nonisolated static func lineEnd(_ string: NSString, _ location: Int) -> Int {
        var end = 0, contentsEnd = 0
        string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return contentsEnd
    }

    /// The same column a line up or down, or that line's end when it's shorter; the first or last line goes to its end.
    static func vertical(_ string: NSString, _ location: Int, up: Bool) -> Int {
        let line = string.lineRange(for: NSRange(location: location, length: 0)), column = location - line.location
        if up {
            guard line.location > 0 else { return 0 }
            let above = string.lineRange(for: NSRange(location: line.location - 1, length: 0))
            return min(above.location + column, lineEnd(string, above.location))
        }
        guard NSMaxRange(line) < string.length || Typing.lineBreak(string, line) > 0 else { return string.length }
        let below = NSMaxRange(line)
        return min(below + column, lineEnd(string, below))
    }
}
