import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import Markdown
import WebKit

/// The editor's Markdown buttons: bold, lists, a table, a heading, a link.
extension MarkdownTab {
    private func edit(_ format: (String, NSRange) -> (text: String, selection: NSRange)) {
        let result = format(editor.text, editor.selectedRange)
        editor.apply(text: result.text, selection: result.selection)
        editor.focus()
    }
    @objc func bold() { edit(MarkdownFormat.toggleBold) }
    @objc func italic() { edit(MarkdownFormat.toggleItalic) }
    @objc func code() { edit(MarkdownFormat.toggleCode) }
    @objc func bullets() { edit(MarkdownFormat.toggleBullet) }
    @objc func numbered() { edit(MarkdownFormat.toggleNumbered) }
    @objc func tasks() { edit(MarkdownFormat.toggleTask) }
    @objc func table() { edit { MarkdownFormat.insertTable($0, $1, columns: 3, rows: 2) } }
    /// Makes the caret's line a heading of `level` (1…3), or text with 0.
    func heading(_ level: Int) { edit { MarkdownFormat.heading($0, $1, level: level) } }
    @objc func headingPicked(_ popUp: NSPopUpButton) {
        let level = popUp.indexOfSelectedItem - 1   // skips the button's face: 0 is Text, then Heading 1…3
        guard level >= 0 else { return }
        heading(level)
    }
    @objc func link() {
        Task {
            guard let address = await prompt(String(localized: "Insert link"), "URL", initial: "https://") else {
                return
            }
            edit { MarkdownFormat.makeLink($0, $1, url: address) }
        }
    }
}
