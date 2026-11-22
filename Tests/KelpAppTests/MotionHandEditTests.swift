import AppKit
import Foundation
import TestSupport
import Testing

@testable import BuiltinFiles
@testable import EditorKit
@testable import KelpKit

extension OneAtATime {
    /// An element moved by hand on a motion page comes back with ⌘Z and goes again with ⇧⌘Z; a second ⌘Z with
    /// nothing left changes nothing.
    @Test func aHandEditOnAMotionPageIsTakenBackAndBroughtAgain() async throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/kelp-motion-undo/.kelp/artifacts/launch/motion.html")
        let page = #"<body data-width="1920" data-height="1080"><h1 data-id="title">Hi</h1></body>"#
        let editor = CodeEditor(text: page, url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        _ = tab.canvasMessage(
            "style", ["board": "motion.html", "id": "title", "property": "translate", "value": "10px 20px"])
        let moved = editor.text
        #expect(moved.contains(#"style="translate: 10px 20px""#))
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == page })
        tab.undoHandEdit(redo: true)
        #expect(try await waitFor(5) { editor.text == moved })
        tab.undoHandEdit(redo: false)
        #expect(try await waitFor(5) { editor.text == page })
        tab.undoHandEdit(redo: false)
        #expect(editor.text == page)
    }
}
