// A file tab's language: run/test/format commands, its project's change bars and language server.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

// MARK: its project and language server
extension FileTab {
    /// The workspaces changed (or weren't known yet when the tab opened): the change bars and the language server follow
    /// the file's project.
    func followProject() {
        guard let editor, let found = ChangeBars.project(of: path, in: app.worktrees),
            changeBars == nil || found.worktree.path != root
        else { return }
        changeBars = ChangeBars(app: app, worktree: found.worktree, file: found.file, editor: editor) { [weak self] in
            self?.isEdited == true
        }
        guard found.worktree.path != root else { return }   // its first bars: the project is the one it had
        if lspOpenedOn != nil {
            LSPManager.of(app).close(root: root, path: path)
            lspOpenedOn = nil
        }
        root = found.worktree.path
        if !remote { startLSP() }
    }

    func startLSP() {
        let filePath = path, projectRoot = root, app = app
        guard LSPManager.of(app).language(filePath)?.server != nil,
            LSPManager.of(app).whenTrusted(projectRoot, { [weak self] in self?.startLSP() })
        else { return }   // asked once per project
        Task { [weak self] in
            guard let text = self?.editor?.text,
                await LSPManager.of(app).open(
                    root: projectRoot, path: filePath, text: text, retry: { [weak self] in self?.startLSP() }),
                let self, let editor
            else { return }
            lspOpenedOn = app.connections
            connectServer(to: editor, root: projectRoot, path: filePath)
        }
    }

    /// LSP: definition of the symbol at the cursor, opened as a tab.
    func jumpToDefinition() {
        guard let editor, let (line, column) = editor.cursor else { return }
        let filePath = path, projectRoot = root, app = app
        Task {
            await lspCaughtUp()
            guard
                let loc = await LSPManager.of(app).definition(
                    root: projectRoot, path: filePath, line: line, column: column)
            else {
                NSSound.beep()
                return
            }
            app.workbench.open(TabURI.file(loc.path, line: loc.line))
        }
    }
}

extension FileTab {
    // MARK: language commands

    var language: LanguageSpec? { LSPManager.of(app).language(path) }

    /// The language's `run`, `test` or `format` with this file's variables filled in. Nil when there's none (a beep
    /// for a file of no language, else a banner).
    func command(_ name: String) async -> String? {
        guard let lang = language, editor != nil else {
            NSSound.beep()
            return nil
        }
        guard let template = lang[command: name] else {
            Banner.show(String(localized: "\(lang.id) has no “\(name)” command."))
            return nil
        }
        let (line, column) = editor?.cursor ?? (1, 1)
        var symbol = ""
        if template.contains("${symbol}") {
            await lspCaughtUp()
            symbol =
                await LSPManager.of(app).symbol(root: root, path: path, line: line)
                ?? LanguageSpec.word(in: editor?.text ?? "", line: line, column: column)
        }
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let vars = [
            "file": path, "relativeFile": relative, "dir": url.deletingLastPathComponent().path,
            "line": String(line), "symbol": symbol, "workspace": root
        ]
        return ShellTemplate.fill(template) { vars[$0] }
    }

    /// Format Document: the text goes to the language's `format` on stdin and comes back formatted, as one undoable
    /// edit with the cursor on its line. A failure shows the command's first lines of error.
    func format() async {
        guard !remote else {
            NSSound.beep()
            return
        }   // its formatter would run here, not on the host
        guard let cmd = await command("format"), let editor else { return }
        guard LSPManager.of(app).askTrust(root, again: true, { [weak self] in Task { await self?.format() } })
        else { return }   // its toolchain may be the repo's
        let text = editor.text, line = editor.cursor?.line ?? 1
        let result = await Shell.run(app, cmd, cwd: url.deletingLastPathComponent().path, input: text, timeout: 20)
        guard result.code == 0 else {
            let why = (result.stderr.isEmpty ? result.stdout : result.stderr).split(separator: "\n").prefix(2).joined(
                separator: "\n")
            Banner.show(String(localized: "Couldn't format \(title): \(why)"), style: .error)
            return
        }
        guard editor.text == text, result.stdout != text, !result.stdout.isEmpty || text.isEmpty else { return }   // typed meanwhile, or nothing to do
        editor.apply(text: result.stdout, selection: NSRange(location: 0, length: 0))
        editor.goTo(line: line)
    }
}
