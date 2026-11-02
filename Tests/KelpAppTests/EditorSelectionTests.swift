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
