import AppKit
import Core
import EditorKit
import KelpKit
import WorkbenchKit

/// What a file's tab says beside its text: its right-click menu and what the language server found.
extension FileTab {
    var selectedText: String? { editor?.selectedText }
    var selectedLines: ClosedRange<Int>? { editor?.selectedLines }
    var reopenURI: String? { TabURI.file(path, line: selectedLines?.lowerBound) }

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

    /// What the language server answers, once it has the file.
    func connectServer(to e: CodeEditor, root r: String, path p: String) {
        let app = app
        e.completionProvider = { line, col in
            await app.lsp.completion(app, root: r, path: p, line: line, column: col).map {
                CodeEditor.Completion(label: $0.label, detail: $0.detail, insert: $0.insert)
            }
        }
        e.hoverProvider = { line, col in
            guard app.settings.bool("editor.hover") != false else { return nil }
            return await app.quiet(LSPHover(root: r, path: p, line: line, column: col)) ?? nil
        }
        e.signatureProvider = { line, col in
            guard app.settings.bool("editor.hover") != false,
                  let found = await app.quiet(LSPSignature(root: r, path: p, line: line, column: col)) ?? nil else { return nil }
            let active = found.activeStart.flatMap { a in found.activeEnd.map { NSRange(location: a, length: $0 - a) } }
            return (found.label, active)
        }
    }
}
