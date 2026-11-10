import AppKit
@testable import EditorKit
import Foundation
import Testing

@testable import KelpKit

extension CodeEditor {
    /// One part of every editor's look, as Settings would change it.
    static func set<T>(_ part: WritableKeyPath<Look, T>, _ value: T) {
        var look = current
        look[keyPath: part] = value
        apply(look: look)
    }
}

/// Settings › Editor › Wrap long lines: new editors start with it, and open ones follow when it changes.
extension OneAtATime {
    @Test func wrapLongLinesReachesNewAndOpenEditors() throws {
        _ = NSApplication.shared
        defer { CodeEditor.set(\.wrapLines, false) }
        let url = URL(fileURLWithPath: "/tmp/wrap.txt")
        func wraps(_ editor: CodeEditor) throws -> Bool {
            try #require(editor.textView.textContainer).widthTracksTextView
        }
        let open = CodeEditor(text: String(repeating: "word ", count: 200), url: url)
        #expect(try !wraps(open))

        CodeEditor.set(\.wrapLines, true)   // the open one follows, nobody telling it
        #expect(try wraps(open))
        #expect(try wraps(CodeEditor(text: "x", url: url)))
    }

    /// A wrapped line goes on at its own indentation; the setting takes it back to the edge.
    @Test func wrappedRowsKeepTheLinesIndentation() throws {
        _ = NSApplication.shared
        CodeEditor.set(\.wrapLines, true)
        defer {
            CodeEditor.set(\.wrapLines, false)
            CodeEditor.set(\.wrappingIndent, .same)
        }
        func secondRow(_ hang: CodeEditor.WrappingIndent) throws -> CGFloat {
            CodeEditor.set(\.wrappingIndent, hang)
            let e = CodeEditor(
                text: "        " + String(repeating: "word ", count: 80), url: URL(fileURLWithPath: "/tmp/wrap.txt"))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.contentView = e.view
            e.view.layoutSubtreeIfNeeded()
            let lm = try #require(e.textView.layoutManager), tc = try #require(e.textView.textContainer)
            lm.ensureLayout(for: tc)
            let first = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let glyph = lm.glyphIndex(for: NSPoint(x: tc.size.width - 1, y: first.maxY + 2), in: tc)
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
        }
        let none = try secondRow(.none), same = try secondRow(.same), more = try secondRow(.indent)
        #expect(none == 0)
        #expect(same > 20)
        #expect(more > same)
    }

    /// The container keeps where the line being laid out starts; an edit before it moves that start, and its rows still
    /// go on at its own indentation.
    @Test func wrappedRowsKeepTheirIndentationAfterAnEditAbove() throws {
        _ = NSApplication.shared
        CodeEditor.set(\.wrapLines, true)
        defer { CodeEditor.set(\.wrapLines, false) }
        let e = CodeEditor(
            text: "xx\n        " + String(repeating: "word ", count: 80), url: URL(fileURLWithPath: "/tmp/wrap.txt"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = e.view
        e.view.layoutSubtreeIfNeeded()
        let lm = try #require(e.textView.layoutManager), tc = try #require(e.textView.textContainer)
        func secondRowOfLine2() -> CGFloat {
            lm.ensureLayout(for: tc)
            let start = (e.textView.string as NSString).range(of: "        ").location
            let first = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            return lm.lineFragmentRect(
                forGlyphAt: lm.glyphIndex(for: NSPoint(x: 5, y: first.maxY + 2), in: tc), effectiveRange: nil
            ).minX
        }
        #expect(secondRowOfLine2() > 20)
        e.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abc")
        // Then a key in that line, which lays it out again (the edit above only moved it).
        e.textView.textStorage?.replaceCharacters(
            in: NSRange(location: e.textView.string.utf16.count, length: 0), with: " more")
        lm.ensureLayout(for: tc)
        let end = e.textView.string.utf16.count - 1   // the row laid out again
        #expect(lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: end), effectiveRange: nil).minX > 20)
    }
}
