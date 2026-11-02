import AppKit
import Core
import EditorKit
import KelpKit

/// What a file's tab says beside its text: its right-click menu and what the language server found.
extension FileTab {
    func contextMenu(_ m: NSMenu) {
        let app = self.app, path = self.path
        let lines = { [weak self] in self?.selectedText?.isEmpty == false ? self?.selectedLines : nil }
        if language?.server != nil { m.add(String(localized: "Jump to Definition")) { [weak self] in self?.jumpToDefinition() } }
        if let p = editor?.problemAtCursor {
            m.add(String(localized: "Fix with Agent")) { FileActions(app).sendToAgent(text: "\(path):\(p.line + 1): \(p.message)") }
        }
        m.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path, lines: lines()) }
        m.add(String(localized: "Copy Path and Line")) { FileActions(app).copyReference(path, lines: lines()) }
        m.addItem(.separator())
        m.add(String(localized: "Toggle Comment")) { [weak self] in self?.editor?.toggleComment() }
    }

    func showProblems() {
        guard let editor else { return }
        let found = app.fileVersions[path]?.problems ?? []
        editor.problems = found.map {
            .init(line: $0.line, column: $0.column, endLine: $0.endLine, endColumn: $0.endColumn, isError: $0.isError, message: $0.message)
        }
        let errors = found.filter(\.isError).count
        statusBar?.show(errors: errors, warnings: found.count - errors)
    }
}
