import AppKit
import Foundation
import Testing

@testable import EditorKit
@testable import KelpKit

@MainActor private func editor(_ text: String) -> CodeEditor {
    CodeEditor(text: text, url: URL(fileURLWithPath: "/find.txt"))
}

@Test func aPlainSearchEscapesWhatARegexWouldTakeAndOptionsNarrowIt() throws {
    var o = FindOptions()
    let s = "a.b axb A.B a.bc" as NSString
    #expect(TextSearch.matches(try TextSearch.pattern("a.b", o), in: s).count == 3)
    o.matchCase = true
    #expect(TextSearch.matches(try TextSearch.pattern("a.b", o), in: s).count == 2)
    o.wholeWord = true
    #expect(TextSearch.matches(try TextSearch.pattern("a.b", o), in: s).count == 1)
    o = FindOptions()
    o.regex = true
    #expect(TextSearch.matches(try TextSearch.pattern("a.b", o), in: s).count == 4)
    #expect(throws: (any Error).self) { try TextSearch.pattern("(", o) }
}

@Test func aReplacementKeepsTheCaseItFoundWhenAsked() {
    #expect(TextSearch.likeIt("cat", "DOG") == "CAT")
    #expect(TextSearch.likeIt("cat", "Dog") == "Cat")
    #expect(TextSearch.likeIt("cat", "dog") == "cat")
}

extension OneAtATime {
    @MainActor @Test func theBarFindsStepsAndReplacesWithGroupsInOneUndo() throws {
        _ = NSApplication.shared
        let e = editor("foo1 bar foo2 bar foo3\n")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        e.openFind(with: "foo(\\d)")
        let bar = try #require(e.findBar)
        bar.flipRegexForTest()
        #expect(e.textView.findMarks.count == 3)
        #expect(e.textView.findCurrent == NSRange(location: 0, length: 4))
        bar.step(forward: true)
        #expect(e.textView.selectedRange() == NSRange(location: 9, length: 4))
        bar.step(forward: false)
        bar.step(forward: false)
        #expect(e.textView.selectedRange().location == 18)   // round the end
        bar.replaceField.stringValue = "n$1"
        bar.replaceAllForTest()
        #expect(e.text == "n1 bar n2 bar n3\n")
        e.undoManager(for: e.textView)?.undo()
        #expect(e.text == "foo1 bar foo2 bar foo3\n")
    }

    /// Typing with the bar open: the matches follow once the keys pause, not on every key.
    @MainActor @Test func theBarsMatchesFollowAnEditOnceTypingPauses() async throws {
        _ = NSApplication.shared
        let e = editor("foo bar\n")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        e.openFind(with: "foo")
        #expect(e.textView.findMarks.count == 1)
        e.textView.setSelectedRange(NSRange(location: 8, length: 0))
        e.textView.insertText("foo foo", replacementRange: e.textView.selectedRange())
        #expect(e.textView.findMarks.count == 1)   // not yet
        try await Task.sleep(for: .milliseconds(400))
        #expect(e.textView.findMarks.count == 3)
    }
}

/// The keys stay in the field, whose field editor is a text view too: a ⌘G sent up the chain would stop there, and the menu's
/// item would even be off. It has to go by the window, the way a key equivalent does before the menu.
@MainActor @Test func cmdGStepsWithTheKeysInTheField() throws {
    _ = NSApplication.shared
    let e = CodeEditor(text: "aa b aa b aa", url: URL(fileURLWithPath: "/tmp/f.txt"))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = e.view
    e.view.layoutSubtreeIfNeeded()
    e.textView.setSelectedRange(NSRange(location: 0, length: 2))
    e.find(.setFindString)
    window.makeFirstResponder(e.findBar?.field)
    #expect(window.firstResponder is NSTextView)
    func press(_ mods: NSEvent.ModifierFlags) throws -> Bool {
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
        return window.performKeyEquivalent(with: key)
    }
    let start = e.textView.selectedRange().location
    #expect(try press(.command))
    let next = e.textView.selectedRange().location
    #expect(next != start)
    #expect(try press([.command, .shift]))
    #expect(e.textView.selectedRange().location == start)
}
