import AppKit
import TestSupport
import Testing

@testable import EditorKit

@MainActor private func opened(_ text: String, _ name: String) -> CodeEditor {
    _ = NSApplication.shared
    let e = CodeEditor(text: text, url: URL(fileURLWithPath: "/tmp/" + name))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
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

@Test func aMirrorShowsItsPlaceholder() {
    let (text, stops) = Snippet.parse("let ${1:name} = $1 + $1;$0")
    #expect(text == "let name = name + name;")
    #expect(stops[0].map(\.location) == [4, 11, 18] && stops[0].map(\.length) == [4, 4, 4])
    #expect(stops[1].first?.location == 23)
    let before = Snippet.parse("$1 ${1:ab}")
    #expect(before.text == "ab ab" && before.stops[0].map(\.location).sorted() == [0, 3])
}

/// With no language server too, in the line's indent, and not after a dot.
@MainActor @Test func aSnippetGoesInWhereTheCursorIs() async throws {
    let e = opened("    te", "s.swift")
    let snippet = CodeEditor.Completion(
        label: "test", insert: "func ${1:a}() {\n\t$0\n}", kind: "snippet", snippet: true)
    e.snippetSource = { [snippet] }
    e.textView.setSelectedRange(NSRange(location: 6, length: 0))
    e.showCompletions()
    #expect(try await waitFor(5) { !(e.completing == nil) })
    #expect(e.completing?.items == [snippet])
    e.accept(snippet)
    #expect(e.text == "    func a() {\n        \n    }")
    #expect(e.textView.selectedRange() == NSRange(location: 9, length: 1))
    e.setText("a.")
    e.textView.setSelectedRange(NSRange(location: 2, length: 0))
    e.showCompletions()
    await mainActorTurns()   // what it looked up is in
    #expect(e.completing == nil)
}

/// A scope's neighbours are those as far in within the same scope; a heading's, those of its level under the same parent.
@MainActor @Test func aScopesSiblingsAreBesideItInTheSameScope() {
    let e = opened(
        "class A {\n    func f() {\n        x\n    }\n    var v = 1\n    func g() {\n        y\n    }\n}\nclass B {\n    func h() {\n    }\n}\n",
        "sib.swift")
    #expect(e.siblingScopes(ofLine: 1).map(\.line) == [1, 5])
    #expect(e.siblingScopes(ofLine: 0).map(\.line) == [0, 9])
    let md = opened("# A\n## a1\ntext\n## a2\n# B\n## b1\n", "sib.md")
    #expect(md.siblingScopes(ofLine: 1).map(\.line) == [1, 3])
    #expect(md.siblingScopes(ofLine: 0).map(\.line) == [0, 4])
}
