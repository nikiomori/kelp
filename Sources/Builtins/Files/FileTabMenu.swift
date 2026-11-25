import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// The parts of a file tab around its text: the right-click menu, and what the language server found or answers.
extension FileTab {
    var selectedText: String? { editor?.selectedText }
    var selectedLines: ClosedRange<Int>? { editor?.selectedLines }
    var reopenURI: String? { TabURI.file(path, line: selectedLines?.lowerBound) }

    /// The language server's actions for this file: what it can change or find.
    var server: LanguageServerActions { LanguageServerActions(app: app, tab: self, root: root) }

    func contextMenu(_ menu: NSMenu) {
        defer { csv?.textItems(menu) }   // a CSV's text has the way back to its table
        let app = self.app, path = self.path
        let lines = { [weak self] in self?.selectedText?.isEmpty == false ? self?.selectedLines : nil }
        if language?.server != nil, !remote {   // a remote file has no language server here
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
        if inProject != nil {
            menu.add(String(localized: "Last Change to This Line")) { [weak self] in self?.showLineOrigin() }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Toggle Comment")) { [weak self] in self?.editor?.toggleComment() }
    }

    func showProblems() {
        guard let editor else { return }
        let found = app.latest(FileEvent.self, path)?.problems ?? []
        editor.problems = found
        let errors = found.filter(\.isError).count
        statusBar?.show(errors: errors, warnings: found.count - errors)
    }

    func sendUnsent() {
        guard let text = lspUnsent else { return }
        lspUnsent = nil
        LSPManager.of(app).change(root: root, path: path, text: text)
    }

    /// Sends the text typed but not yet sent, before the server is asked about a place in the file. That way the
    /// question is about text the server has (`foo.` asks for the members of foo, not for a column the server lacks).
    func lspCaughtUp() async {
        lspTask?.cancel()
        sendUnsent()
        await LSPManager.of(app).sent()
    }

    /// Connects the editor's completion, hover and signature help to the language server, once the server has the file.
    func connectServer(to codeEditor: CodeEditor, root projectRoot: String, path filePath: String) {
        let app = app
        codeEditor.onDefinition = { [weak self] in self?.jumpToDefinition(beside: $0) }   // ⌘-click, ⌥⌘-click
        codeEditor.completionProvider = { [weak self] line, col in
            await self?.lspCaughtUp()
            return await LSPManager.of(app).completion(root: projectRoot, path: filePath, line: line, column: col)
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
}

/// Copies the link to a file (or to its lines) on its forge. Used by the file tab's menu, the Files panel's menu and
/// Copy Web Link.
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
    /// Returns the remote project that holds a file, from the remote projects this app's home keeps (KELP_HOME/remote).
    static func containing(_ path: String) -> (folder: String, remote: RemoteHost, remotePath: String)? {
        Remotes(home: Paths.root).containing(path)
    }
}
