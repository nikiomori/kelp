import AppKit
import Foundation
import TestSupport
import Testing

@testable import EditorKit

@Test(arguments: [
    ("", true), ("   ", true), (")", true), ("})", true), ("\";", true), ("x)", false), (" foo", false)
])
func aSuggestionFitsBeforeOnlyClosersOrNothing(rest: String, fits: Bool) {
    #expect(InlineSuggestion.fits(beforeRest: Substring(rest)) == fits)
}

@Test(
    arguments: [
        // raw answer, rest of the line, text below the cursor, what shows
        ("$0.price * $0.count }", "}", "\n}", "$0.price * $0.count "),
        ("count  ", "", "", "count"),
        ("price)\n", ")", "", "price"),
        ("let a = 1\n    return a\n}\n", "", "\n}\n", "let a = 1\n    return a"),
        ("   \n  ", "", "", nil),
        ("x\r\ny", "", "", "x\ny"),
        (")", ")", "", nil),
        ("\n    a\n  ", "}", "", "\n    a\n  ")   // the closer goes on a line of its own
    ] as [(String, String, String, String?)])
func aModelsAnswerLosesWhatsAlreadyThere(raw: String, rest: String, below: String, shown: String?) {
    #expect(InlineSuggestion.cleaned(raw, rest: Substring(rest), below: below) == shown)
}

@Test(
    arguments: [
        // raw answer, the cursor line's indent, what shows: it ends with the cursor's block
        ("return s == s[::-1]\n\nprint(is_palindrome(\"racecar\"))", 4, "return s == s[::-1]"),
        ("a = 1\n    b = 2\nc = 3", 4, "a = 1\n    b = 2"),
        ("x)\n  }\n}", 4, "x)\n  }\n}"),   // lines that only close stay, however far out
        ("one\ntwo", 0, "one\ntwo")
    ] as [(String, Int, String)])
func aSuggestionEndsWithTheCursorsBlock(raw: String, indent: Int, shown: String) {
    #expect(InlineSuggestion.cleaned(raw, rest: "", below: "", indent: indent) == shown)
    #expect(InlineSuggestion.indent(of: "func f() {\n" + String(repeating: " ", count: indent)) == indent)
}

@Test func aSuggestionStopsAfterItsLineLimit() {
    let raw = (1...30).map { "line\($0)" }.joined(separator: "\n")
    let shown = InlineSuggestion.cleaned(raw, rest: "", below: "")
    #expect(shown?.components(separatedBy: "\n").count == InlineSuggestion.lineLimit)
}

@Test func typingWhatsShownShortensIt() {
    #expect(InlineSuggestion.remaining("count }", after: "co") == "unt }")
    #expect(InlineSuggestion.remaining("count }", after: "cx") == nil)
    #expect(InlineSuggestion.remaining("count", after: "count") == nil)   // all of it typed: nothing left to show
}

@Test(arguments: [("count }", "count"), ("  price * 2", "  price"), (".map { $0 }", "."), ("x", "x")])
func optionRightTakesAWord(shown: String, word: String) {
    #expect(InlineSuggestion.nextWord(of: shown) == word)
}

@MainActor private enum KeptWindows { static var all: [NSWindow] = [] }

/// The gray text in a real editor: asked for after typing, typed through, taken with ⇥ or a word at a time, dropped.
extension OneAtATime {
    private func suggesting(_ text: String, answer: String) -> (CodeEditor, EditorTextView) {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/suggest.swift"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        KeptWindows.all.append(window)
        window.makeFirstResponder(e.textView)
        e.suggestionDelay = .zero
        e.suggestionProvider = { _ in answer }
        e.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (e, e.textView)
    }

    private func type(_ tv: EditorTextView, _ s: String) {
        tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func settled(_ e: CodeEditor) async throws -> Bool {
        try await waitFor(2) { e.isSuggesting }
    }

    @Test func tabPutsInTheGrayTextAndTypingShortensIt() async throws {
        let (e, tv) = suggesting("let total = ", answer: "rice * count")
        type(tv, "p")
        #expect(try await settled(e))
        type(tv, "r")   // typed what it shows: shorter, still there
        #expect(e.isSuggesting)
        tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(tv.string == "let total = price * count")
        #expect(!e.isSuggesting)
        type(tv, "x")   // typed something else: gone until the next answer
        #expect(!e.isSuggesting)
    }

    @Test func optionRightTakesOneWordAndEscapeDropsIt() async throws {
        let (e, tv) = suggesting("x = ", answer: "price * count")
        type(tv, " ")
        #expect(try await settled(e))
        var events: [Bool] = []
        e.onSuggestion = { events.append($0) }
        tv.doCommand(by: #selector(NSResponder.moveWordRight(_:)))
        #expect(tv.string == "x =  price")
        #expect(e.isSuggesting)   // the rest still shows, as if typed
        tv.doCommand(by: #selector(NSResponder.moveWordRight(_:)))
        #expect(tv.string == "x =  price *")
        #expect(events == [true])   // taken once, however many words
        tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!e.isSuggesting)
        #expect(tv.string == "x =  price *")   // Esc keeps what was taken
    }

    @Test func movingTheCursorOrTextAfterItAsksNothing() async throws {
        let (e, tv) = suggesting("a = foo", answer: "bar")
        tv.setSelectedRange(NSRange(location: 4, length: 0))   // before "foo": the rest of the line isn't closers
        type(tv, " ")
        #expect(e.suggestion.task == nil)   // not even asked
        tv.setSelectedRange(NSRange(location: tv.length, length: 0))
        type(tv, " ")
        #expect(try await settled(e))
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!e.isSuggesting)
    }
}

@Test func theWindowBeforeTheCursorStaysPutWhileYouType() {
    let text = String(repeating: "let value = 1\n", count: 1000) as NSString   // 14 000 characters, lines of 14
    let start = InlineSuggestion.windowStart(at: 9000, in: text)
    #expect(InlineSuggestion.windowStart(at: 9003, in: text) == start)   // three keys later: the same start
    #expect(start % 14 == 0)   // at a line's start
    #expect(9000 - start >= InlineSuggestion.prefixLimit)   // never less than the limit back
    #expect(InlineSuggestion.windowStart(at: 100, in: text) == 0)
}
