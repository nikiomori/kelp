import AppKit
import Foundation
import Testing
@testable import EditorKit
@testable import KelpKit

extension OneAtATime {
    private func editor(_ text: String, _ name: String = "sel.swift", at i: Int) -> CodeEditor {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/" + name))
        e.textView.setSelectedRange(NSRange(location: i, length: 0))
        return e
    }

    /// It grows by what the code is, each step around the last, and comes back the way it went.
    @Test func selectionGrowsBySyntaxAndShrinksBack() {
        let e = editor("let x = foo(bar, baz)\n", at: 12)
        var seen: [NSRange] = [e.textView.selectedRange()]
        for _ in 0..<4 {
            e.expandSelection()
            let r = e.textView.selectedRange(), last = seen[seen.count - 1]
            #expect(r.length > last.length && NSIntersectionRange(r, last) == last)
            seen.append(r)
        }
        e.shrinkSelection()
        #expect(e.textView.selectedRange() == seen[3])
        e.shrinkSelection()
        e.shrinkSelection()
        #expect(e.textView.selectedRange() == seen[1])
    }

    /// Without a grammar: the word, the line, everything.
    @Test func withNoGrammarItGoesWordLineAll() {
        let e = editor("one two\nthree\n", "sel.unknownext", at: 5)
        e.expandSelection()
        #expect(e.textView.selectedRange() == NSRange(location: 4, length: 3))
        e.expandSelection()
        #expect(e.textView.selectedRange() == NSRange(location: 0, length: 8))
        e.expandSelection()
        #expect(e.textView.selectedRange().length == 14)
    }

    @Test func cursorsGoAboveBelowAndToLineEnds() {
        let e = editor("abc\ndef\nghi\n", "sel.txt", at: 5)
        e.addCursor(above: false)
        e.addCursor(above: true)
        #expect(e.textView.cursors.map(\.location) == [1, 5, 9])
        e.textView.setSelectedRange(NSRange(location: 1, length: 6))
        e.cursorsAtLineEnds()
        #expect(e.textView.cursors.map(\.location) == [3, 7])
    }
}

@MainActor @Test func aHoversMarkdownKeepsItsCodeAndLosesItsFences() {
    let t = HoverText.attributed("```swift\nfunc f()\n```\nReturns **all** of it.")
    #expect(t.string == "func f()\nReturns all of it.")
    #expect((t.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
}

@MainActor @Test func aHoverCardIsAsTallAsItsTextUpToItsMost() {
    let short = HoverCard(NSAttributedString(string: "one line"), width: 300, most: 200)
    let long = HoverCard(NSAttributedString(string: String(repeating: "line\n", count: 100)), width: 300, most: 200)
    _ = short.view
    _ = long.view
    #expect(short.preferredContentSize.height > 0 && short.preferredContentSize.height < 100)
    #expect(long.preferredContentSize.height == 200)
}

@MainActor @Test func theEditorSaysAndTakesItsTopLine() {
    _ = NSApplication.shared
    let e = CodeEditor(text: (1...400).map { "line \($0)\n" }.joined(), url: URL(fileURLWithPath: "/t.txt"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = e.view
    e.view.layoutSubtreeIfNeeded()
    #expect(e.topLine == 1)
    e.scroll(toLine: 120)
    #expect(abs(e.topLine - 120) <= 1)
}

@MainActor @Test func wrappingStopsAtItsColumnOrTheEdge() throws {
    _ = NSApplication.shared
    let e = CodeEditor(text: String(repeating: "word ", count: 100), url: URL(fileURLWithPath: "/t.swift"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = e.view
    e.view.layoutSubtreeIfNeeded()
    e.wrapsHere = true
    e.wrapColumn = 20
    let tc = try #require(e.textView.textContainer)
    let wide = tc.size.width
    #expect(wide < 300)
    e.wrapColumn = 10
    #expect(tc.size.width < wide)
    e.wrapColumn = 1000
    #expect(tc.size.width <= e.textView.bounds.width)
    e.wrapColumn = nil
    #expect(tc.widthTracksTextView)
}

@MainActor @Test func spacesNobodyMeansToHaveAreKnown() {
    #expect(EditorTextView.isUnusualSpace(0xA0) && EditorTextView.isUnusualSpace(0x200B) && EditorTextView.isUnusualSpace(0xFEFF))
    #expect(!EditorTextView.isUnusualSpace(32) && !EditorTextView.isUnusualSpace(9) && !EditorTextView.isUnusualSpace(97))
}

@MainActor private func foldEditor(_ text: String, _ name: String) -> CodeEditor {
    _ = NSApplication.shared
    return CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/" + name))
}

@MainActor private func hidden(_ e: CodeEditor, line n: Int) -> String? {
    let s = e.text as NSString
    var at = 0
    for _ in 1..<n { at = NSMaxRange(s.lineRange(for: NSRange(location: at, length: 0))) }
    return e.foldRegion(s.lineRange(for: NSRange(location: at, length: 0)), in: s).map { s.substring(with: $0) }
}

/// Oddly indented code folds by what it is, a long string too, and the closing brace stays.
@MainActor @Test func foldsFollowTheCodeNotItsIndentation() {
    let e = foldEditor("func f() {\nlet a = 1\nlet b = 2\n}\nlet s = \"\"\"\none\ntwo\n\"\"\"\n", "fold.swift")
    #expect(hidden(e, line: 1) == "\nlet a = 1\nlet b = 2")
    #expect(hidden(e, line: 5)?.contains("two") == true)
    #expect(hidden(e, line: 2) == nil)
}

@MainActor @Test func marksRegionsAndHeadingsFold() {
    let code = foldEditor("// MARK: One\nlet a = 1\n\n// MARK: Two\nlet b = 2\n//#region x\nlet c = 3\n//#endregion\n", "marks.swift")
    #expect(hidden(code, line: 1) == "\nlet a = 1")
    #expect(hidden(code, line: 6) == "\nlet c = 3\n//#endregion")
    let md = foldEditor("# A\ntext\n## B\nmore\n# C\nend\n", "doc.md")
    #expect(hidden(md, line: 1) == "\ntext\n## B\nmore")
    #expect(hidden(md, line: 3) == "\nmore")
}

@MainActor @Test func foldAllTakesTheOutermostAndALevelGoesDeeper() {
    let e = foldEditor("class A {\n    func f() {\n        let x = 1\n    }\n}\n", "lvl.swift")
    e.foldAll()
    #expect(e.textView.folds.hidden.count == 1)
    e.unfoldAll()
    e.foldAll(level: 2)
    #expect(e.textView.folds.hidden.count == 1)
    #expect((e.text as NSString).substring(with: e.textView.folds.hidden[0]).contains("let x") )
    #expect(!(e.text as NSString).substring(with: e.textView.folds.hidden[0]).contains("func"))
}

@MainActor @Test func theScopesAroundTheTopLineStayPinned() throws {
    let body = (1...200).map { "        let v\($0) = \($0)\n" }.joined()
    let e = foldEditor("class A {\n    func f() {\n\(body)    }\n}\n", "sticky.swift")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = e.view
    e.view.layoutSubtreeIfNeeded()
    #expect(e.stickyLines().isEmpty)
    e.scroll(toLine: 100)
    #expect(e.stickyLines() == [0, 1])
    let md = foldEditor("# A\n\n## B\n\n" + String(repeating: "text\n", count: 100), "sticky.md")
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    other.contentView = md.view
    md.view.layoutSubtreeIfNeeded()
    md.scroll(toLine: 50)
    #expect(md.stickyLines() == [0, 2])
}

@MainActor @Test func theScrollerMarksWhatsInTheFile() throws {
    let e = foldEditor((1...100).map { "line \($0)\n" }.joined(), "ticks.txt")
    e.problems = [.init(line: 50, column: 0, endLine: 50, endColumn: 2, isError: true, message: "x")]
    e.changeMarks = [.init(kind: .added, line: 10, count: 1, hunk: 0)]
    let marks = try #require((e.scroll as? EditorScrollView)?.marks)
    #expect(marks.ticks.map(\.line).sorted() == [0, 10, 50])
    #expect(marks.lines == 101)
}

/// A whole text applied (⌘S's tidying, a format) replaces only what differs: a fold elsewhere stays, and one undo
/// gives the text back.
@MainActor @Test func applyingATextKeepsWhatItDidntChange() throws {
    let e = foldEditor("func a() {\n    x\n}\nfunc b() {\n    y   \n}\n", "keep.swift")
    let fold = NSRange(location: 10, length: 6)
    e.textView.setFolded(fold, true)
    e.apply(text: "func a() {\n    x\n}\nfunc b() {\n    y\n}\n", selection: NSRange(location: 0, length: 0))
    #expect(e.text == "func a() {\n    x\n}\nfunc b() {\n    y\n}\n")
    #expect(e.textView.folds.fold(at: fold.location) != nil)
    e.undoManager(for: e.textView)?.undo()
    #expect(e.text == "func a() {\n    x\n}\nfunc b() {\n    y   \n}\n")
}
