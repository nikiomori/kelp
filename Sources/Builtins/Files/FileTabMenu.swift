import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// What a file's tab says beside its text: its right-click menu and what the language server found.
extension FileTab {
    var selectedText: String? { editor?.selectedText }
    var selectedLines: ClosedRange<Int>? { editor?.selectedLines }
    var reopenURI: String? { TabURI.file(path, line: selectedLines?.lowerBound) }

    /// What the language server can change or find from here.
    var server: ServerActions { ServerActions(app: app, tab: self, root: root) }

    func contextMenu(_ menu: NSMenu) {
        let app = self.app, path = self.path
        let lines = { [weak self] in self?.selectedText?.isEmpty == false ? self?.selectedLines : nil }
        if language?.server != nil, !remote {   // a host's file has no language server here
            menu.add(String(localized: "Jump to Definition")) { [weak self] in self?.jumpToDefinition() }
            menu.add(String(localized: "Find References")) { [weak self] in self?.server.findReferences() }
            menu.add(String(localized: "Rename Symbol…")) { [weak self] in self?.server.rename() }
            menu.add(String(localized: "Quick Fix…")) { [weak self] in self?.server.quickFix() }
        }
        if let problem = editor?.problemAtCursor {
            menu.add(String(localized: "Fix with Agent")) {
                FileActions(app).sendToAgent(text: "\(path):\(problem.line + 1): \(problem.message)")
            }
        }
        menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path, lines: lines()) }
        menu.add(String(localized: "Copy Path and Line")) { FileActions(app).copyReference(path, lines: lines()) }
        menu.addItem(.separator())
        menu.add(String(localized: "Toggle Comment")) { [weak self] in self?.editor?.toggleComment() }
    }

    func showProblems() {
        guard let editor else { return }
        let found = app.latest(FileEvent.self, path)?.problems ?? []
        editor.problems = found.map {
            .init(
                line: $0.line, column: $0.column, endLine: $0.endLine, endColumn: $0.endColumn, isError: $0.isError,
                message: $0.message)
        }
        let errors = found.filter(\.isError).count
        statusBar?.show(errors: errors, warnings: found.count - errors)
    }

    func sendUnsent() {
        guard let text = lspUnsent else { return }
        lspUnsent = nil
        LSPManager.of(app).change(root: root, path: path, text: text)
    }

    /// Before asking the server about a place in the file: what's typed and not sent yet goes first, so the question is
    /// about the text it has (`foo.` asks for foo's members, not for a column it hasn't got).
    func lspCaughtUp() async {
        lspTask?.cancel()
        sendUnsent()
        await LSPManager.of(app).sent()
    }

    /// What the language server answers, once it has the file.
    func connectServer(to codeEditor: CodeEditor, root projectRoot: String, path filePath: String) {
        let app = app
        codeEditor.completionProvider = { [weak self] line, col in
            await self?.lspCaughtUp()
            return await LSPManager.of(app).completion(root: projectRoot, path: filePath, line: line, column: col)
                .map {
                    CodeEditor.Completion(
                        label: $0.label, detail: $0.detail, insert: $0.insert, kind: $0.kind,
                        documentation: $0.documentation,
                        snippet: $0.snippet == true, edit: $0.edit.map(Self.edit), more: ($0.more ?? []).map(Self.edit))
                }
        }
        codeEditor.hoverProvider = { [weak self] line, col in
            guard app.settings[SettingKeys.hover] else { return nil }
            await self?.lspCaughtUp()
            return await app.quiet(LSPHover(root: projectRoot, path: filePath, line: line, column: col)) ?? nil
        }
        codeEditor.signatureProvider = { [weak self] line, col in
            guard app.settings[SettingKeys.hover] else { return nil }
            await self?.lspCaughtUp()
            guard
                let found = await app.quiet(LSPSignature(root: projectRoot, path: filePath, line: line, column: col))
                    ?? nil
            else {
                return nil
            }
            let active = found.activeStart.flatMap { a in found.activeEnd.map { NSRange(location: a, length: $0 - a) } }
            return (found.label, active)
        }
    }

    private static func edit(_ codeEdit: CodeEdit) -> CodeEditor.TextEdit {
        .init(
            line: codeEdit.line, column: codeEdit.column, endLine: codeEdit.endLine, endColumn: codeEdit.endColumn,
            text: codeEdit.text)
    }
}

/// A file's (or its lines') link on its forge, copied: from its tab's menu, the Files panel's and Copy Web Link.
@MainActor
func copyWebLink(_ app: AppModel, _ path: String, lines: ClosedRange<Int>? = nil) {
    Task {
        guard let url = await app.call(GitWebURL(path: path, start: lines?.lowerBound, end: lines?.upperBound))
        else { return }
        copyText(url)
        Banner.show(String(localized: "Link copied"))
    }
}

extension RemoteHost {
    /// The remote project a file is in, as this app's home keeps them (KELP_HOME/remote).
    static func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? {
        Remotes(home: Paths.root).containing(path)
    }
}
