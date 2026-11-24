import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// The "prompt:<path>" tab: the text an agent handed to its external editor (`kelp edit`, Ctrl+G), to be written at
/// length. Closing the tab puts the text back in the agent's prompt, for you to send; Cancel leaves the prompt as it
/// was. Either way, `kelp edit` is told through a file beside the prompt's file, and that lets the agent go on.
/// Limit: a tab restored after a restart has nobody waiting for it. Read again, it closes if its file went.
@MainActor
final class PromptTab: TabContent {
    let uri: String, app: AppModel
    let view: NSView
    private let path: String
    private var editor: CodeEditor?
    /// The file's version as it was read or last found, so an edit saved meanwhile (in another tab of the same file)
    /// isn't written over without asking.
    private var stamp: FileStamp?
    private var cancelled = false
    var title: String { String(localized: "Prompt") }
    var icon: NSImage? { .symbol("text.bubble") }

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        path = TabURI.promptPath(uri)
        view = EditorBox()
        let path = path
        Task { [weak self] in
            let read = await app.tryCall(FilesRead(path: path))
            guard let self else { return }
            guard let read = read.value else {
                app.workbench.closeTab(uri: uri, remember: false)
                return
            }
            stamp = read.stamp
            show(read.text)
        }
    }

    private func show(_ text: String) {
        let codeEditor = CodeEditor(text: text, url: URL(fileURLWithPath: path))
        codeEditor.view.clipsToBounds = true
        codeEditor.alwaysWraps = true
        codeEditor.refreshAppearance()
        editor = codeEditor
        let cancel = TextButton(String(localized: "Cancel")) { [weak self] in self?.cancel() }
        cancel.restFill = nil   // quieter than Done
        let done = TextButton(String(localized: "Done")) { [weak self] in self?.finish() }
        let label = NSTextField.sentence(String(localized: "Closing this tab puts the text in the agent’s prompt"))
        label.textColor = .secondaryLabelColor
        let bar = Bar.content([label], [cancel, done], stretching: label)
        view.pin(stacked(bar, codeEditor.view))
        focus()
    }

    func focus() { editor?.focus() }
    /// The text in the tab's editor (for tests).
    var typed: String? { editor?.text }
    func type(_ text: String) { editor?.setText(text) }

    private func finish() { app.workbench.closeTab(uri: uri, remember: false) }
    private func cancel() {
        cancelled = true
        finish()
    }

    /// Writes the file before the tab closes, because the agent reads the file once `kelp edit` ends.
    /// When the file changed since it was read, the tab stays open and says so; closing again writes this text anyway.
    func close() async -> Bool {
        if !cancelled, let text = editor?.text {
            guard let written = await app.call(FilesWrite(path: path, text: text, base: stamp)) else { return false }
            if let conflict = written.conflict {
                stamp = conflict.stamp
                Banner.show(
                    String(localized: "The prompt was changed elsewhere. Close again to keep yours, or Cancel."))
                return false
            }
        }
        await app.call(FilesWrite(path: path + TabURI.promptDone, text: "", base: nil))
        return true
    }
}
