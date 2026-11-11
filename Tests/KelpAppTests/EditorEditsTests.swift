import AppKit
import Foundation
import TestSupport
import Testing
import os

@testable import EditorKit
@testable import KelpKit

/// Windows the editors sit in for a test (colors go to what's on screen): kept, as a view only holds its window weakly.
@MainActor private enum Kept { static var windows: [NSWindow] = [] }

/// The code editor's editing: VS Code's commands, more than one cursor, typing that indents and pairs.
extension OneAtATime {
    private func editor(_ text: String, _ name: String = "edits.swift", selecting ranges: [NSRange]) -> (
        CodeEditor, EditorTextView
    ) {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/" + name))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        Kept.windows.append(window)
        e.textView.setCursors(ranges)
        return (e, e.textView)
    }

    private func type(_ tv: EditorTextView, _ s: String) {
        tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func marks(_ tv: EditorTextView) -> [Int] {
        let lm = tv.layoutManager!
        return (0..<tv.length).filter {
            lm.temporaryAttribute(.backgroundColor, atCharacterIndex: $0, effectiveRange: nil) != nil
        }
    }

    @Test func bracketMarksGoWithTheTextAndNoneStaysBehind() throws {
        let (e, tv) = editor("(a)\nbar", "marks.txt", selecting: [NSRange(location: 0, length: 0)])
        e.markBrackets()
        #expect(marks(tv) == [0, 2])
        tv.setCursors([NSRange(location: 4, length: 0)])
        #expect(marks(tv) == [])
        tv.setCursors([NSRange(location: 0, length: 0)])
        e.setText("xx(a)\nbar")   // text above the marks moves them
        #expect(e.marked == [NSRange(location: 2, length: 1), NSRange(location: 4, length: 1)])
        tv.setCursors([NSRange(location: 6, length: 0)])
        #expect(marks(tv) == [])
    }

    @Test func aFileChangedOnDiskKeepsWhatItDidntChange() {
        let (e, tv) = editor("one\ntwo\nthree\nfour", selecting: [NSRange(location: 15, length: 0)])
        tv.setFolded(NSRange(location: 8, length: 5), true)
        e.setText("ONE!\ntwo\nthree\nfour")
        #expect(tv.string == "ONE!\ntwo\nthree\nfour")
        #expect(tv.cursors == [NSRange(location: 16, length: 0)])   // after the change: moved along
        #expect(tv.folds.hidden == [NSRange(location: 9, length: 5)])
        #expect(e.lineCount == 4)
        e.setText("ONE!\ntwo\nthree\nfour\nfive")
        #expect(e.lineCount == 5)
        #expect(tv.undoManager?.canUndo == false)   // the disk's change isn't an edit of yours
    }

    @Test func whatChangedNeverSplitsASurrogatePair() {
        let (old, new) = CodeEditor.changed("a😀b", "a😁b")   // same high half, different low half
        #expect(old == NSRange(location: 1, length: 2) && new == NSRange(location: 1, length: 2))
        let same = CodeEditor.changed("abab", "ab")
        #expect(same.old == NSRange(location: 2, length: 2) && same.new == NSRange(location: 2, length: 0))
    }

    @Test func aFileWithAVeryLongLineIsOnlyShown() {
        let line = String(repeating: "x", count: 99_999)
        #expect(CodeEditor.canEdit(""))
        #expect(CodeEditor.canEdit(line + "\n" + line + "\n" + line))
        #expect(!CodeEditor.canEdit(line + "\n" + line + "xx\nend"))
        #expect(!CodeEditor.canEdit("start\n" + line + "xxx"))
        #expect(!CodeEditor.canEdit(String(repeating: "short\n", count: CodeEditor.readOnlyLimit / 5)))
    }

    @Test func aFileOfVeryLongLinesIsNotColoredAndAHugeOneIsNotParsed() {
        let long = "[" + String(repeating: "1,", count: CodeEditor.colorSpan) + "1]"
        let (e, tv) = editor(long, "long.json", selecting: [NSRange(location: 0, length: 0)])
        tv.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: tv.length))   // as the gutter's first draw does
        e.colorVisible()
        #expect(e.colored == nil)
        #expect(tv.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil) == nil)
        let huge = String(repeating: "x", count: CodeEditor.readOnlyLimit + 1)
        #expect(CodeEditor(text: huge, url: URL(fileURLWithPath: "/tmp/huge.json"), editable: false).highlighter == nil)
    }

    @Test func commandDSelectsTheWordThenEachNextOccurrenceWrappingAround() {
        let (e, tv) = editor("foo bar foo\nfoo", selecting: [NSRange(location: 9, length: 0)])
        e.addNextOccurrence()
        #expect(tv.cursors == [NSRange(location: 8, length: 3)])
        e.addNextOccurrence()
        #expect(tv.cursors == [NSRange(location: 8, length: 3), NSRange(location: 12, length: 3)])
        e.addNextOccurrence()
        #expect(
            tv.cursors == [
                NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 12, length: 3)
            ])
        e.selectAllOccurrences()
        #expect(tv.cursors.count == 3)
    }

    /// The bug that took Kelp off CodeEditTextView: typing over several selections put the later cursors in the wrong place.
    @Test func typingOverSeveralSelectionsLeavesEachCursorAfterItsText() throws {
        let (e, tv) = editor(
            "foo bar foo\nfoo\n", selecting: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
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
        let (e, _) = editor(
            "a\nb\nc\nd", selecting: [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
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
        let (e, tv) = editor(
            "a b\nc\nd", selecting: [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
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
        e.useIndent(tabWidth: 2, spaces: true)   // the file indents by two, as its tab found (`Indentation.detect`)
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.text == "  if x {\n    \n  }")
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
        #expect(keyword == CodeEditor.colors.keyword)
        #expect(string == CodeEditor.colors.string)
        type(tv, "var ")   // colored again after an edit, the tree following it
        e.colorVisible()
        #expect(
            lm.temporaryAttribute(.foregroundColor, atCharacterIndex: 4, effectiveRange: nil) as? NSColor
                == CodeEditor.colors.keyword)
    }

    @Test func aLongLineScrollsSidewaysUnlessItWraps() throws {
        defer { CodeEditor.set(\.wrapLines, false) }
        let (e, tv) = editor(String(repeating: "word ", count: 400), selecting: [NSRange(location: 0, length: 0)])
        tv.layoutManager?.ensureLayout(for: try #require(tv.textContainer))
        tv.sizeToFit()
        #expect(tv.frame.width > 1000)
        CodeEditor.set(\.wrapLines, true)
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

    // MARK: From the review of the new editor

    /// Right after the dot the list has everything; a letter narrows it; ⇥ puts the item in, past what was typed.
    @Test func completionNarrowsAsYouTypeAndTakesTheWordTyped() async throws {
        let (e, tv) = editor("obj.", selecting: [NSRange(location: 4, length: 0)])
        e.completionProvider = { _, _ in
            [.init(label: "name", insert: "name()"), .init(label: "other", insert: "other")]
        }
        e.showCompletions()
        #expect(try await waitFor(5) { !(e.completion.list?.isOpen != true) })
        #expect(e.completion.list?.items.count == 2)
        tv.insertText("n", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(e.completion.list?.items.map(\.label) == ["name"])
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(e.text == "obj.name()")
        #expect(e.completion.list?.isOpen == false)
    }

    /// A word begun asks the server by itself, once: the letters after it narrow what came.
    @Test func aWordBegunOpensTheCompletionList() async throws {
        let (e, tv) = editor("", selecting: [NSRange(location: 0, length: 0)])
        let asked = OSAllocatedUnfairLock(initialState: 0)
        e.completionProvider = { _, _ in
            asked.withLock { $0 += 1 }
            return [.init(label: "print", insert: "print"), .init(label: "private", insert: "private")]
        }
        for key in ["p", "r"] { tv.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(try await waitFor(5) { e.completion.list?.isOpen == true })
        tv.insertText("in", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(e.completion.list?.items.map(\.label) == ["print"])
        #expect(asked.withLock { $0 } == 1)
        e.closeCompletions()
        tv.insertText(" 1", replacementRange: NSRange(location: NSNotFound, length: 0))   // a number isn't a name
        #expect(asked.withLock { $0 } == 1)
    }

    /// Esc closes it, the cursor leaving the word too, and keys go back to the text.
    @Test func escAndMovingAwayCloseTheCompletionList() async throws {
        let (e, tv) = editor("a.b", selecting: [NSRange(location: 2, length: 0)])
        e.completionProvider = { _, _ in [.init(label: "b", insert: "b")] }
        e.showCompletions()
        #expect(try await waitFor(5) { !(e.completion.list?.isOpen != true) })
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(e.completion.list?.isOpen == false)
        e.showCompletions()
        #expect(try await waitFor(5) { !(e.completion.list?.isOpen != true) })
        tv.setCursors([NSRange(location: 0, length: 0)])
        #expect(e.completion.list?.isOpen == false)
    }

    /// An import the item needs comes in the same undo as the item, and the cursor lands after the item.
    @Test func aCompletionsOtherEditsComeWithIt() {
        let (e, tv) = editor("\nfo", selecting: [NSRange(location: 3, length: 0)])
        e.textView.setSelectedRange(NSRange(location: 3, length: 0))
        e.accept(
            .init(
                label: "foo", insert: "foo", edit: .init(line: 1, column: 0, endLine: 1, endColumn: 2, text: "foo"),
                more: [.init(line: 0, column: 0, endLine: 0, endColumn: 0, text: "import x\n")]))
        #expect(e.text == "import x\n\nfoo")
        #expect(tv.selectedRange().location == 13)
        e.undoManager(for: tv)?.undo()
        #expect(e.text == "\nfo")
    }

    /// ⇥ goes through a snippet's stops, what's typed at one moving the next, and the same number twice is two cursors.
    @Test func aSnippetsStopsFollowTab() {
        let (e, tv) = editor("", selecting: [NSRange(location: 0, length: 0)])
        e.accept(.init(label: "f", insert: "func ${1:name}($2) -> $1 {\n\t$0\n}", snippet: true))
        #expect(e.text == "func name() -> name {\n    \n}")
        #expect(tv.cursors.count == 2)
        tv.insertText("go", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(e.text.hasPrefix("func go() -> go {"))
        #expect(tv.selectedRange().location == 8)
        tv.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(e.text == "func go(a) -> go {\n    \n}")
        #expect(tv.selectedRange().location == 23)
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))   // past the last stop
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))   // over: a Tab is a tab again
        #expect(e.text != "func go(a) -> go {\n    \n}")
    }

    @Test func returnOnTheLastLineShownBringsTheNewLineIntoView() throws {
        let (_, tv) = editor(String(repeating: "x\n", count: 200), selecting: [NSRange(location: 400, length: 0)])
        tv.scrollRangeToVisible(tv.selectedRange())
        for _ in 0..<5 { tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(tv.visibleRect.contains(tv.caretRect(at: tv.selectedRange().location)))
    }

    @Test func returnInsideTheIndentDoesntDoubleIt() {
        let (e, tv) = editor("    foo", selecting: [NSRange(location: 0, length: 0)])
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.text == "\n    foo")
        let (e2, tv2) = editor("    foo", selecting: [NSRange(location: 2, length: 0)])
        tv2.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e2.text == "  \n    foo")
    }

    @Test func aWindowsFileKeepsItsLineBreaks() {
        let (e, tv) = editor("a\r\nb", selecting: [NSRange(location: 1, length: 0)])
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(e.text == "a\r\n\r\nb")
        tv.setCursors([NSRange(location: 5, length: 0)])
        e.deleteLines()
        #expect(e.text == "a\r\n")
        e.copyLines(down: true)
        #expect(!e.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func occurrencesOfAWordFromTheCursorAreWholeWords() {
        let (e, tv) = editor("id width valid id", selecting: [NSRange(location: 1, length: 0)])
        e.selectAllOccurrences()
        #expect(tv.cursors == [NSRange(location: 0, length: 2), NSRange(location: 15, length: 2)])
    }

    @Test func pasteWordMovesAndShiftWorkAtEveryCursor() {
        let (e, tv) = editor(
            "ab cd\nef gh\n", selecting: [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)])
        tv.doCommand(by: #selector(NSResponder.moveWordRight(_:)))
        #expect(tv.cursors == [NSRange(location: 2, length: 0), NSRange(location: 8, length: 0)])
        tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        tv.doCommand(by: #selector(NSResponder.moveWordRightAndModifySelection(_:)))
        #expect(tv.cursors == [NSRange(location: 2, length: 3), NSRange(location: 8, length: 3)])
        tv.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:)))   // the moving end goes back
        #expect(tv.cursors == [NSRange(location: 2, length: 2), NSRange(location: 8, length: 2)])
        tv.pasteboard = NSPasteboard.withUniqueName()   // not the user's clipboard
        defer { tv.pasteboard.releaseGlobally() }
        tv.pasteboard.setString("1\n2\n", forType: .string)
        tv.paste(nil)
        #expect(e.text == "ab1d\nef2h\n")   // a line each
        tv.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))
        #expect(e.text == "d\nh\n")
    }

    @Test func commandSlashUsesBlockCommentsWhereALanguageHasNoLineOnes() {
        let (css, _) = editor("a { color: red; }\n", "s.css", selecting: [NSRange(location: 0, length: 0)])
        css.toggleComment()
        #expect(css.text == "/* a { color: red; } */\n")
        css.toggleComment()
        #expect(css.text == "a { color: red; }\n")
    }

    @Test func movingTheLastLineKeepsAWholeLineSelection() {
        let (e, tv) = editor("a\nb", selecting: [NSRange(location: 0, length: 2)])
        e.moveLines(down: true)
        #expect(e.text == "b\na")
        #expect(tv.cursors == [NSRange(location: 2, length: 1)])
    }

    @Test func aTripleClickedLineIsOneLineForSendToAgent() {
        let (e, _) = editor("a\nb\nc\n", selecting: [NSRange(location: 2, length: 2)])
        #expect(e.selectedLines == 2...2)
    }

    // MARK: Folding and brackets

    @Test func aBlockFoldsByIndentKeepingItsClosingLine() throws {
        let (e, tv) = editor("func f() {\n    a\n    b\n}\n", selecting: [NSRange(location: 0, length: 0)])
        e.fold()
        #expect(tv.folds.hidden == [NSRange(location: 10, length: 12)])   // the end of `{` to the end of `b`; `}` stays
        let lm = try #require(tv.layoutManager)
        #expect(lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: 15)) == .null)
        #expect(lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: 23)) != .null)
        e.unfold()
        #expect(tv.folds.isEmpty)
        #expect(lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: 15)) != .null)
    }

    @Test func aFoldMovesWithEditsBeforeItAndOpensForOnesInIt() {
        let (e, tv) = editor("def f():\n    x = 1\n\nprint()\n", "a.py", selecting: [NSRange(location: 0, length: 0)])
        e.fold()
        #expect(tv.folds.hidden == [NSRange(location: 8, length: 10)])
        tv.insertText("#", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(tv.folds.hidden == [NSRange(location: 9, length: 10)])
        tv.setCursors([NSRange(location: 14, length: 0)])   // the cursor inside: it opens
        #expect(tv.folds.isEmpty)
        e.fold()
        tv.replace([NSRange(location: 12, length: 1)], with: ["y"])
        #expect(tv.folds.isEmpty)
    }

    @Test func foldFromInsideABlockFoldsTheBlockAroundIt() {
        let (e, tv) = editor("a {\n  b {\n    c\n  }\n  d\n}\n", selecting: [NSRange(location: 22, length: 0)])   // on `d`
        e.fold()
        #expect(tv.folds.hidden == [NSRange(location: 3, length: 20)])   // `a {`'s block: `b {` … `d`
    }

    @Test func theBracketBesideTheCursorAndItsPartnerAreMarked() throws {
        let (e, tv) = editor("f(a, (b)) + \"(\"\n", selecting: [NSRange(location: 9, length: 0)])
        let lm = try #require(tv.layoutManager)
        func marked(_ i: Int) -> Bool {
            lm.temporaryAttribute(.backgroundColor, atCharacterIndex: i, effectiveRange: nil) != nil
        }
        e.markBrackets()
        #expect(marked(1) && marked(8) && !marked(5))
        tv.setCursors([NSRange(location: 6, length: 0)])   // after the inner (
        #expect(marked(5) && marked(7) && !marked(1))
        #expect(Brackets.partner(of: 13, in: tv.string as NSString, tree: e.highlighter?.tree) == nil)   // in a string
    }

    @Test func languagesInsideAFileGetTheirColors() throws {
        let md = "# Title\n\nSome `code` here.\n\n```swift\nlet x = 1\n```\n"
        let (e, tv) = editor(md, "a.md", selecting: [NSRange(location: 0, length: 0)])
        e.colorVisible()
        let lm = try #require(tv.layoutManager), s = md as NSString
        func color(_ needle: String) -> NSColor? {
            lm.temporaryAttribute(.foregroundColor, atCharacterIndex: s.range(of: needle).location, effectiveRange: nil)
                as? NSColor
        }
        #expect(color("Title") == CodeEditor.colors.keyword)
        #expect(color("code") == CodeEditor.colors.string)   // Markdown's inline grammar, inside a paragraph
        #expect(color("let") == CodeEditor.colors.keyword)   // Swift's, inside the fenced block
        #expect(color("x =") == nil)   // not the block's string color: Swift's colors alone
    }

    /// Each step of a scroll asked tree-sitter for three screens on the main thread, and a scroll spent most of its time there.
    @Test func whatsColoredIsColoredOnceUntilTheTextChanges() throws {
        let text = (0..<3000).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let (e, tv) = editor(text, selecting: [NSRange(location: 0, length: 0)])
        e.colorVisible()
        let first = try #require(e.colored)
        let screen = tv.visibleRect.height
        tv.scroll(NSPoint(x: 0, y: screen / 2))
        e.colorVisible()
        #expect(e.colored == first)   // still in what's colored
        tv.scroll(NSPoint(x: 0, y: screen * 5))
        e.colorVisible()
        #expect(e.colored != first)
        // A file this size is parsed as it's typed, with no `parsed` after it: what's typed gets its colors all the same.
        let lm = try #require(tv.layoutManager), at = try #require(e.colored).location
        tv.setCursors([NSRange(location: at, length: 0)])
        type(tv, "let ")
        e.colorVisible()
        #expect(
            lm.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil) as? NSColor
                == CodeEditor.colors.keyword)
    }

    @Test func theContextMenuIsACodeEditorsOwn() throws {
        let (e, tv) = editor("let x = 1", selecting: [NSRange(location: 0, length: 3)])
        e.contextMenu = { m in m.addItem(withTitle: "Send to Agent", action: nil, keyEquivalent: "") }
        let click = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(tv.menu(for: click))
        #expect(menu.items.map(\.title) == ["Cut", "Copy", "Paste", "", "Send to Agent"])
        #expect(!menu.allowsContextMenuPlugIns)   // no Services, no Siri
        #expect(menu.items.map(\.keyEquivalent).joined().isEmpty)   // HIG: shortcuts belong to the main menus
        if #available(macOS 15.0, *) { #expect(tv.writingToolsBehavior == .none) }
    }
}
