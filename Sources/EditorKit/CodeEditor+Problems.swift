import AppKit
import Core
import DesignKit

/// What a language server says is wrong: underlined in the text, told apart in the line numbers, and said in the hover
/// card (CodeEditor+Hover).
extension CodeEditor {
    /// Core's, as the daemon sends it.
    public typealias Problem = CodeProblem

    func problemsChanged() {
        let string = textView.string as NSString
        textView.problemMarks = problems.compactMap { problem -> EditorTextView.ProblemMark? in
            let start = lineIndex.offset(line: problem.line, column: problem.column, in: string)
            guard let from = start else { return nil }
            // A server may name a point, so the mark takes the character there.
            let end = lineIndex.offset(line: problem.endLine, column: problem.endColumn, in: string)
            let to = max(end ?? from, min(from + 1, string.length))
            return .init(
                range: NSRange(location: from, length: to - from), isError: problem.isError, message: problem.message)
        }.sorted { $0.range.location < $1.range.location }
        problemLines = problems.reduce(into: [:]) { lines, problem in
            lines[problem.line] = (lines[problem.line] ?? false) || problem.isError
        }
        textView.needsDisplay = true
        gutter?.needsDisplay = true
        refreshScrollMarks()
    }

    /// The problem the cursor is in or touches.
    public var problemAtCursor: Problem? {
        let cursor = textView.selectedRange().location
        guard
            let mark = textView.problemMarks.first(where: {
                cursor >= $0.range.location && cursor <= NSMaxRange($0.range)
            })
        else {
            return nil
        }
        return problems.first { $0.message == mark.message }
    }

    /// F8 goes to the next problem past the cursor, or the last before it, going round the file.
    public func goToProblem(forward: Bool) {
        let marks = textView.problemMarks, cursor = textView.selectedRange().location
        guard
            let next = forward
                ? marks.first(where: { $0.range.location > cursor }) ?? marks.first
                : marks.last(where: { $0.range.location < cursor }) ?? marks.last
        else {
            NSSound.beep()
            return
        }
        textView.setSelectedRange(NSRange(location: next.range.location, length: 0))
        textView.scrollRangeToVisible(next.range)
        focus()
    }
}

extension EditorTextView {
    public struct ProblemMark: Equatable {
        let range: NSRange, isError: Bool, message: String
    }

    /// Draws a wavy line under each mark in what's drawn, because a font's underline has no such style.
    func drawProblems(in rect: NSRect) {
        guard !problemMarks.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let shown = characters(in: rect.insetBy(dx: 0, dy: -20))
        let origin = textContainerOrigin
        for mark in problemMarks
        where NSIntersectionRange(mark.range, shown).length > 0 && !folds.intersects(mark.range) {
            (mark.isError ? NSColor.textRed : NSColor.textOrange).setStroke()
            lm.enumerateEnclosingRects(
                forGlyphRange: lm.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc
            ) { lineRect, _ in
                // Under the text, which stands in the middle of its line.
                let baseline = lineRect.maxY + origin.y - 1.5 - CodeEditor.lineExtra / 2, wave = NSBezierPath()
                var along = lineRect.minX + origin.x, up = true
                wave.move(to: NSPoint(x: along, y: baseline))
                while along < lineRect.maxX + origin.x {
                    along += 2
                    wave.line(to: NSPoint(x: along, y: baseline + (up ? -1 : 1)))
                    up.toggle()
                }
                wave.lineWidth = 1
                wave.stroke()
            }
        }
    }
}
