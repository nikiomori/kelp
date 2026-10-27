import AppKit

/// The arrows, Home and End and Esc with more than one cursor: each cursor moves (Esc keeps the first). Other commands
/// run for the first cursor alone.
@MainActor enum MultiCursor {
    /// False for a command that isn't a move.
    static func move(_ tv: EditorTextView, _ command: Selector) -> Bool {
        let s = tv.string as NSString
        let to: (NSRange) -> Int
        switch command {
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)):
            to = { $0.length > 0 ? $0.location : $0.location > 0 ? s.rangeOfComposedCharacterSequence(at: $0.location - 1).location : 0 }
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
            to = { $0.length > 0 || $0.location >= s.length ? NSMaxRange($0) : NSMaxRange(s.rangeOfComposedCharacterSequence(at: $0.location)) }
        case #selector(NSResponder.moveUp(_:)): to = { vertical(s, $0.location, up: true) }
        case #selector(NSResponder.moveDown(_:)): to = { vertical(s, NSMaxRange($0), up: false) }
        case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)),
             #selector(NSResponder.moveToBeginningOfParagraph(_:)):
            to = { s.lineRange(for: NSRange(location: $0.location, length: 0)).location }
        case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)),
             #selector(NSResponder.moveToEndOfParagraph(_:)):
            to = { lineEnd(s, NSMaxRange($0)) }
        case #selector(NSResponder.cancelOperation(_:)):
            tv.setCursors([tv.cursors[0]])
            return true
        default: return false
        }
        tv.setCursors(tv.cursors.map { NSRange(location: to($0), length: 0) })
        return true
    }

    /// Where the line holding `i` ends, before its line break.
    static func lineEnd(_ s: NSString, _ i: Int) -> Int {
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
