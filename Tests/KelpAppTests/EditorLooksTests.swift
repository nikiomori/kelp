import AppKit
import Testing
@testable import EditorKit

@MainActor private func opened(_ text: String, _ name: String) -> CodeEditor {
    _ = NSApplication.shared
    let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/" + name))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = e.view
    e.view.layoutSubtreeIfNeeded()
    return e
}

@MainActor private func color(_ e: CodeEditor, at i: Int) -> NSColor? {
    e.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor
}

/// `{` depth 0, `(` depth 1, and the bracket in the string isn't one; a colour is the same scrolled away from the start.
@MainActor @Test func bracketsColorByDepthFromTheCode() {
    let e = opened("func f() {\n    g(\"(\")\n}\n", "b.swift")
    let s = e.text as NSString
    let plain = color(e, at: s.range(of: "(\"").location)
    e.bracketColors = true
    let brace = color(e, at: s.range(of: "{").location), paren = color(e, at: s.range(of: "(\"").location)
    #expect(paren != plain && paren != brace)
    #expect(color(e, at: s.range(of: "}").location) == brace)
    #expect(color(e, at: s.range(of: "(\"").location + 2) != paren)
}

@MainActor @Test func aFilesGrammarNeedNotNameItsBrackets() {
    let e = opened("{\"a\": [1, {\"b\": 2}]}\n", "b.json")
    e.bracketColors = true
    let s = e.text as NSString
    #expect(color(e, at: 0) != color(e, at: s.range(of: "[").location))
    #expect(color(e, at: 0) == color(e, at: s.length - 2))
}

@MainActor @Test func indentLevelsFollowTheFilesIndent() {
    let e = opened("", "i.swift")
    e.useIndent(tabWidth: 2, spaces: true)
    let s = "    x\n\tx\n\n" as NSString, tv = e.textView
    #expect(tv.indentLevel(NSRange(location: 0, length: 6), in: s) == 2)
    #expect(tv.indentLevel(NSRange(location: 6, length: 3), in: s) == 1)
    #expect(tv.indentLevel(NSRange(location: 9, length: 1), in: s) == nil)
}

@MainActor @Test func theScopesAtTheCursorComeFromTheCode() {
    let e = opened("class A {\n    func f() {\n        let x = 1\n    }\n}\n", "s.swift")
    e.goTo(line: 3)
    #expect(e.scopesAtCursor.map(\.line) == [0, 1])
    #expect(e.scopesAtCursor.last?.text == "    func f() {")
    e.goTo(line: 1)
    #expect(e.scopesAtCursor.isEmpty)
}
