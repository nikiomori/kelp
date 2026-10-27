import AppKit
import Foundation
import Testing
@testable import EditorKit
@testable import KelpKit

/// Windows the editors sit in for a test (colors go to what's on screen): kept, as a view only holds its window weakly.
@MainActor private enum Kept { static var windows: [NSWindow] = [] }

/// The code editor's editing: VS Code's commands, more than one cursor, typing that indents and pairs.
extension OneAtATime {
    private func editor(_ text: String, _ name: String = "edits.swift", selecting ranges: [NSRange]) -> (CodeEditor, EditorTextView) {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/" + name))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = e.view
        Kept.windows.append(window)
        e.textView.setCursors(ranges)
        return (e, e.textView)
    }

    private func type(_ tv: EditorTextView, _ s: String) { tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }

    @Test func commandDSelectsTheWordThenEachNextOccurrenceWrappingAround() {
        let (e, tv) = editor("foo bar foo\nfoo", selecting: [NSRange(location: 9, length: 0)])
        e.addNextOccurrence()
        #expect(tv.cursors == [NSRange(location: 8, length: 3)])
        e.addNextOccurrence()
        #expect(tv.cursors == [NSRange(location: 8, length: 3), NSRange(location: 12, length: 3)])
        e.addNextOccurrence()
        #expect(tv.cursors == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 12, length: 3)])
        e.selectAllOccurrences()
        #expect(tv.cursors.count == 3)
    }

    /// The bug that took Kelp off CodeEditTextView: typing over several selections put the later cursors in the wrong place.
    @Test func typingOverSeveralSelectionsLeavesEachCursorAfterItsText() throws {
        let (e, tv) = editor("foo bar foo\nfoo\n", selecting: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        type(tv, "X")
        #expect(e.text == "X bar X\nfoo\n")
        #expect(tv.cursors == [NSRange(location: 1, length: 0), NSRange(location: 7, length: 0)])
        type(tv, "y")
        #expect(e.text == "Xy bar Xy\nfoo\n")
        tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(e.text == " bar \nfoo\n")
        let undo = try #require(tv.undoManager)
        while undo.canUndo { undo.undo() }
        #expect(e.text == "foo bar foo\nfoo\n")
    }

    @Test func arrowsMoveEveryCursorAndEscKeepsTheFirst() {
        let (_, tv) = editor("ab\ncd\n", selecting: [NSRange(location: 1, length: 0), NSRange(location: 4, length: 0)])
        tv.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(tv.cursors == [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)])
        tv.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(tv.cursors == [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(tv.cursors == [NSRange(location: 0, length: 0)])
    }

    @Test func deleteLinesTakesTheTouchedLinesAndTheLastLinesNewline() {
        let (e, _) = editor("a\nb\nc\nd", selecting: [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
        e.deleteLines()
        #expect(e.text == "a\nc")
    }

    @Test func copyLinesDownMovesTheSelectionToTheCopyUpKeepsIt() {
        let (e, tv) = editor("one\ntwo", selecting: [NSRange(location: 5, length: 1)])
        e.copyLines(down: true)
        #expect(e.text == "one\ntwo\ntwo")
        #expect(tv.cursors == [NSRange(location: 9, length: 1)])
        e.copyLines(down: false)
        #expect(e.text == "one\ntwo\ntwo\ntwo")
        #expect(tv.cursors == [NSRange(location: 9, length: 1)])
    }

    @Test func moveLinesTakesALineOnceWhateverTheCursorsOnIt() {
        let (e, tv) = editor("a b\nc\nd", selecting: [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
        e.moveLines(down: true)
        #expect(e.text == "c\na b\nd")
        #expect(tv.cursors == [NSRange(location: 2, length: 0), NSRange(location: 4, length: 0)])
        e.moveLines(down: true)   // past the last line, which has no newline
        #expect(e.text == "c\nd\na b")
        e.moveLines(down: true)   // at the bottom: stays
        #expect(e.text == "c\nd\na b")
        e.moveLines(down: false)
        e.moveLines(down: false)
        #expect(e.text == "a b\nc\nd")
        #expect(tv.cursors == [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
    }

    @Test func aTripleClickedLineCopiesAlone() {
        let (e, _) = editor("x\ny\n", selecting: [NSRange(location: 0, length: 2)])
        e.copyLines(down: true)
        #expect(e.text == "x\nx\ny\n")
    }

    @Test func returnIndentsLikeTheLineAboveAndOpensABracePair() {
        let (e, tv) = editor("  if x {}", selecting: [NSRange(location: 8, length: 0)])
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.text == "  if x {\n    \n  }")   // the file indents by two
        #expect(tv.cursors == [NSRange(location: 13, length: 0)])
    }

    @Test func bracketsAndQuotesComeInPairsAndAClosingOneStepsOver() {
        let (e, tv) = editor("", selecting: [NSRange(location: 0, length: 0)])
        type(tv, "f")
        type(tv, "(")
        #expect(e.text == "f()")
        type(tv, "\"")
        #expect(e.text == "f(\"\")")
        type(tv, "\"")
        type(tv, ")")
        #expect(e.text == "f(\"\")")
        #expect(tv.cursors == [NSRange(location: 5, length: 0)])
        let (e2, tv2) = editor("don", selecting: [NSRange(location: 3, length: 0)])
        type(tv2, "'")
        #expect(e2.text == "don'")   // an apostrophe, not a pair
    }

    @Test func commandSlashCommentsTheLinesAtTheirLeastIndentAndBack() {
        let (e, _) = editor("a\n  b\n", selecting: [NSRange(location: 0, length: 5)])
        e.toggleComment()
        #expect(e.text == "// a\n//   b\n")
        e.toggleComment()
        #expect(e.text == "a\n  b\n")
        let (py, _) = editor("x = 1\n", "a.py", selecting: [NSRange(location: 0, length: 0)])
        py.toggleComment()
        #expect(py.text == "# x = 1\n")
    }

    @Test func indentAndOutdentTheTouchedLines() {
        let (e, tv) = editor("a\n\nb", selecting: [NSRange(location: 0, length: 4)])
        e.indent(out: false)
        #expect(e.text == "    a\n\n    b")   // a blank line stays blank
        #expect(tv.cursors == [NSRange(location: 0, length: 12)])
        e.indent(out: true)
        #expect(e.text == "a\n\nb")
    }

    @Test func keywordsAndStringsGetTheirColors() throws {
        let (e, tv) = editor("let s = \"hi\"\n", selecting: [NSRange(location: 0, length: 0)])
        e.colorVisible()
        let lm = try #require(tv.layoutManager)
        let keyword = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
        let string = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: 9, effectiveRange: nil) as? NSColor
        #expect(keyword == CodeEditor.look.keyword)
        #expect(string == CodeEditor.look.string)
        type(tv, "var ")   // colored again after an edit, the tree following it
        e.colorVisible()
        #expect(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: 4, effectiveRange: nil) as? NSColor == CodeEditor.look.keyword)
    }

    @Test func aLongLineScrollsSidewaysUnlessItWraps() throws {
        defer { CodeEditor.wrapLines = false }
        let (e, tv) = editor(String(repeating: "word ", count: 400), selecting: [NSRange(location: 0, length: 0)])
        tv.layoutManager?.ensureLayout(for: try #require(tv.textContainer))
        tv.sizeToFit()
        #expect(tv.frame.width > 1000)
        CodeEditor.wrapLines = true
        e.refreshAppearance()
        #expect(tv.frame.width <= 400)
    }

    @Test func cursorAndLinesCountFromOneAndFollowEdits() {
        let (e, tv) = editor("a\nbc\nd", selecting: [NSRange(location: 4, length: 0)])
        #expect(e.cursor?.line == 2)
        #expect(e.cursor?.column == 3)
        tv.setCursors([NSRange(location: 0, length: 0)])
        type(tv, "x\n")
        tv.setCursors([NSRange(location: 6, length: 0)])
        #expect(e.cursor?.line == 3)
        e.goTo(line: 4)
        #expect(tv.selectedRange().location == 7)
    }

    @Test func setTextIsNoEditAndNoUndo() {
        let (e, tv) = editor("old", selecting: [NSRange(location: 3, length: 0)])
        var changes = 0
        e.onChange = { _ in changes += 1 }
        e.setText("new text")
        #expect(changes == 0)
        #expect(tv.undoManager?.canUndo == false)
        #expect(e.text == "new text")
    }
}
