import AppKit
import DesignKit

/// What a language server says is wrong: underlined in the text, told apart in the line numbers, a tooltip on each.
extension CodeEditor {
    public struct Problem: Equatable, Sendable {
        /// 0-based, UTF-16 units, as the server counts.
        public let line: Int, column: Int, endLine: Int, endColumn: Int, isError: Bool, message: String
        public init(line: Int, column: Int, endLine: Int, endColumn: Int, isError: Bool, message: String) {
            self.line = line
            self.column = column
            self.endLine = endLine
            self.endColumn = endColumn
            self.isError = isError
            self.message = message
        }
    }

    func problemsChanged() {
        let string = textView.string as NSString
        func offset(_ line: Int, _ column: Int) -> Int? {
            lineIndex.start(ofLine: line, in: string).map { min($0 + column, string.length) }
        }
        textView.problemMarks = problems.compactMap { problem -> EditorTextView.ProblemMark? in
            guard let from = offset(problem.line, problem.column) else { return nil }
            // A server may name a point: the mark takes the character there.
            let to = max(offset(problem.endLine, problem.endColumn) ?? from, min(from + 1, string.length))
            return .init(
                range: NSRange(location: from, length: to - from), isError: problem.isError, message: problem.message)
        }.sorted { $0.range.location < $1.range.location }
        problemLines = problems.reduce(into: [:]) { lines, problem in
            lines[problem.line] = (lines[problem.line] ?? false) || problem.isError
        }
        textView.needsDisplay = true
        gutter?.needsDisplay = true
        showProblemTips()
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

    /// F8: the next one past the cursor, or the last before it, going round the file.
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

    /// Tooltips on what's on screen, made again as it scrolls: a view takes them per rectangle.
    func showProblemTips() {
        let tv = textView
        tv.removeAllToolTips()
        guard !tv.problemMarks.isEmpty, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let shown = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc), actualGlyphRange: nil)
        for (index, mark) in tv.problemMarks.enumerated() where NSIntersectionRange(mark.range, shown).length > 0 {
            lm.enumerateEnclosingRects(
                forGlyphRange: lm.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc
            ) { glyphRect, _ in
                let rect = glyphRect.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
                tv.addToolTip(rect, owner: tv, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
            }
        }
    }
}

extension EditorTextView: NSViewToolTipOwner {
    public struct ProblemMark: Equatable {
        let range: NSRange, isError: Bool, message: String
    }

    public func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?
    ) -> String {
        let index = Int(bitPattern: data) - 1
        return problemMarks.indices.contains(index) ? problemMarks[index].message : ""
    }

    /// A wavy line under each mark in what's drawn: a font's underline has no such style.
    func drawProblems(in rect: NSRect) {
        guard !problemMarks.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let shown = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect.insetBy(dx: 0, dy: -20), in: tc), actualGlyphRange: nil)
        let origin = textContainerOrigin
        for mark in problemMarks
        where NSIntersectionRange(mark.range, shown).length > 0 && !folds.intersects(mark.range) {
            (mark.isError ? NSColor.textRed : NSColor.textOrange).setStroke()
            lm.enumerateEnclosingRects(
                forGlyphRange: lm.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc
            ) { lineRect, _ in
                let y = lineRect.maxY + origin.y - 1.5, wave = NSBezierPath()
                var x = lineRect.minX + origin.x, up = true
                wave.move(to: NSPoint(x: x, y: y))
                while x < lineRect.maxX + origin.x {
                    x += 2
                    wave.line(to: NSPoint(x: x, y: y + (up ? -1 : 1)))
                    up.toggle()
                }
                wave.lineWidth = 1
                wave.stroke()
            }
        }
    }
}
