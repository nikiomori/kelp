import AppKit
import Foundation
import Testing
@testable import EditorKit
@testable import KelpKit

/// VS Code's editing keys in the code editor: ⌘D, ⇧⌘L, ⇧⌘K, ⇧⌥↑↓.
extension OneAtATime {
    @MainActor private func editor(_ text: String, selecting ranges: [NSRange]) throws -> (CodeEditor, () -> [NSRange]) {
        _ = NSApplication.shared
        let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/edits.swift"))
        _ = e.view
        let tv = try #require(e.controller.textView)
        tv.selectionManager.setSelectedRanges(ranges)
        return (e, { tv.selectionManager.textSelections.map(\.range) })
    }

    @Test func commandDSelectsTheWordThenEachNextOccurrenceWrappingAround() throws {
        let (e, sels) = try editor("foo bar foo\nfoo", selecting: [NSRange(location: 9, length: 0)])
        e.addNextOccurrence()
        #expect(sels() == [NSRange(location: 8, length: 3)])
        e.addNextOccurrence()
        #expect(sels() == [NSRange(location: 8, length: 3), NSRange(location: 12, length: 3)])
        e.addNextOccurrence()
        #expect(sels() == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 12, length: 3)])
        e.selectAllOccurrences()
        #expect(sels().count == 3)
    }

    @Test func deleteLinesTakesTheTouchedLinesAndTheLastLinesNewline() throws {
        let (e, _) = try editor("a\nb\nc\nd", selecting: [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
        e.deleteLines()
        #expect(e.text == "a\nc")
    }

    @Test func copyLinesDownMovesTheSelectionToTheCopyUpKeepsIt() throws {
        let (e, sels) = try editor("one\ntwo", selecting: [NSRange(location: 5, length: 1)])
        e.copyLines(down: true)
        #expect(e.text == "one\ntwo\ntwo")
        #expect(sels() == [NSRange(location: 9, length: 1)])
        e.copyLines(down: false)
        #expect(e.text == "one\ntwo\ntwo\ntwo")
        #expect(sels() == [NSRange(location: 9, length: 1)])
    }

    @Test func moveLinesTakesALineOnceWhateverTheCursorsOnIt() throws {
        let (e, sels) = try editor("a b\nc\nd", selecting: [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
        e.moveLines(down: true)
        #expect(e.text == "c\na b\nd")
        #expect(sels() == [NSRange(location: 2, length: 0), NSRange(location: 4, length: 0)])
        e.moveLines(down: true)   // past the last line, which has no newline
        #expect(e.text == "c\nd\na b")
        e.moveLines(down: true)   // at the bottom: stays
        #expect(e.text == "c\nd\na b")
        e.moveLines(down: false)
        e.moveLines(down: false)
        #expect(e.text == "a b\nc\nd")
        #expect(sels() == [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
    }

    @Test func aTripleClickedLineCopiesAlone() throws {
        let (e, _) = try editor("x\ny\n", selecting: [NSRange(location: 0, length: 2)])
        e.copyLines(down: true)
        #expect(e.text == "x\nx\ny\n")
    }
}
