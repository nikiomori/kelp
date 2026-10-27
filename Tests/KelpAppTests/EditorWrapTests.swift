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
}
