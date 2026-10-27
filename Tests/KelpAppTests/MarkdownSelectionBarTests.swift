import AppKit
import Foundation
import Testing
import EditorKit
@testable import KelpKit
@testable import BuiltinFiles

/// The Markdown editor's formatting: a bar floats over a selection, the strip's buttons hide in the preview.
extension OneAtATime {
    @Test func aBarFloatsOverASelectionAndGoesWithIt() throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/tmp/bar.md")
        let editor = CodeEditor(text: "# Plan\n\nWrite the spec.\n", url: url)
        let tab = MarkdownTab(editor: editor, url: url, app: AppModel())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tab.view
        tab.view.layoutSubtreeIfNeeded()
        if tab.currentMode != "edit" { tab.cycleMode() }   // preview → edit
        tab.view.layoutSubtreeIfNeeded()
        let bar = try #require(tab.view.subviews.first { $0 is MarkdownSelectionBar })
        editor.textView.setSelectedRange(NSRange(location: 14, length: 4))   // "spec"
        #expect(!bar.isHidden)
        let word = try #require(editor.selectionRect)
        #expect(bar.frame.minY >= tab.view.convert(word, from: editor.view).maxY)   // above it (the view isn't flipped)
        editor.textView.setSelectedRange(NSRange(location: 14, length: 0))
        #expect(bar.isHidden)
        editor.textView.setSelectedRange(NSRange(location: 14, length: 4))
        tab.cycleMode()   // edit → preview (split is skipped in a pane this narrow)
        #expect(tab.currentMode == "preview")
        #expect(bar.isHidden)
    }
}
