import AppKit
import Foundation
import Testing
import EditorKit
@testable import KelpKit

/// Settings › Editor › Wrap long lines: new editors start with it, and open ones follow when it changes.
extension OneAtATime {
    @Test func wrapLongLinesReachesNewAndOpenEditors() throws {
        _ = NSApplication.shared
        defer { CodeEditor.wrapLines = false }
        let url = URL(fileURLWithPath: "/tmp/wrap.txt")
        func wraps(_ editor: CodeEditor) throws -> Bool {
            try #require(editor.textView.textContainer).widthTracksTextView
        }
        let open = CodeEditor(text: String(repeating: "word ", count: 200), url: url)
        #expect(try !wraps(open))

        CodeEditor.wrapLines = true
        open.refreshAppearance()
        #expect(try wraps(open))
        #expect(try wraps(CodeEditor(text: "x", url: url)))
    }

    /// A wrapped line goes on at its own indentation; the setting takes it back to the edge.
    @Test func wrappedRowsKeepTheLinesIndentation() throws {
        _ = NSApplication.shared
        CodeEditor.wrapLines = true
        defer { CodeEditor.wrapLines = false; CodeEditor.wrappingIndent = .same }
        func secondRow(_ hang: CodeEditor.WrappingIndent) throws -> CGFloat {
            CodeEditor.wrappingIndent = hang
            let e = CodeEditor(text: "        " + String(repeating: "word ", count: 80), url: URL(fileURLWithPath: "/tmp/wrap.txt"))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
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
}
