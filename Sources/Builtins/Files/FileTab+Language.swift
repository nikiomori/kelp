// How a file tab follows its language: the run, test and format commands, and the change bars and language server
// of the file's project.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import SwiftUI
import WorkbenchKit

// MARK: its project and language server
extension FileTab {
    /// Moves the change bars and the language server to the file's project. Called when the workspaces change, or when
    /// they weren't known yet as the tab opened.
    func followProject() {
        guard let editor, let found = ChangeBars.project(of: path, in: app.worktrees),
            changeBars == nil || found.worktree.path != root
        else { return }
        changeBars = ChangeBars(app: app, worktree: found.worktree, file: found.file, editor: editor) { [weak self] in
            self?.isEdited == true
        }
        guard found.worktree.path != root else { return }   // the first bars, for the project the tab already had
        if lspOpenedOn != nil {
            LSPManager.of(app).close(root: root, path: path)
            lspOpenedOn = nil
        }
        root = found.worktree.path
        if !remote { startLSP() }
    }

    func startLSP() {
        let filePath = path, projectRoot = root, app = app
        guard LSPManager.of(app).language(filePath)?.allServers.isEmpty == false,
            LSPManager.of(app).whenTrusted(projectRoot, { [weak self] in self?.startLSP() })
        else { return }   // waits until the project is trusted (asked once per project)
        if lspOpenedOn != nil {   // a restart (a server was installed since): close the file on the old servers first
            LSPManager.of(app).close(root: projectRoot, path: filePath)
            lspOpenedOn = nil
        }
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

    /// Makes the status bar name the file's language servers. A click lists them, with how to install a missing one.
    func nameServers(in bar: EditorStatusBar) {
        let app = app
        bar.onServers = { [weak self] button in
            guard let self, let language else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(
                rootView: FileServers(app: app, language: language, root: root, file: url.lastPathComponent))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        track(owner: self) { [weak self] in
            self.flatMap { LSPManager.of(app).summary($0.root, $0.language) }
        } changed: { [weak bar] in
            bar?.show(servers: $0)
        }
    }

    /// Opens the definition of the symbol at the cursor as a tab (`beside`: in a split to the right), as the language
    /// server finds it, or says there is none. A lookup over a second says so in the status bar.
    func jumpToDefinition(beside: Bool = false) {
        guard let editor, let (line, column) = editor.cursor else { return }
        let filePath = path, projectRoot = root, app = app, bar = statusBar
        Task {
            let slow = whileSlow { bar?.showFinding() }
            await lspCaughtUp()
            let found = await LSPManager.of(app).definition(
                root: projectRoot, path: filePath, line: line, column: column)
            slow.cancel()
            await bar?.found()
            guard let loc = found else {
                Banner.show(String(localized: "No definition found."))
                return
            }
            app.workbench.open(TabURI.file(loc.path, line: loc.line), split: beside ? .right : nil)
        }
    }
}

extension FileTab {
    // MARK: language commands

    var language: LanguageSpec? { LSPManager.of(app).language(path) }

    /// Returns the language's `run`, `test` or `format` command with this file's variables filled in. Returns nil when
    /// there is no such command, with a beep for a file with no language and a banner otherwise.
    func command(_ name: String) async -> String? {
        guard let lang = language, editor != nil else {
            NSSound.beep()
            return nil
        }
        guard let template = lang[command: name] else {
            Banner.show(String(localized: "\(lang.id) has no “\(name)” command."))
            return nil
        }
        let line = editor?.cursor?.line ?? 1
        var symbol = ""
        if template.contains("${symbol}") {
            await lspCaughtUp()
            symbol =
                await LSPManager.of(app).symbol(root: root, path: path, line: line)
                ?? editor?.wordAtCursor ?? ""
        }
        let inside = Paths.relative(path, to: root), relative = inside ?? path
        // A remote project's command runs on its host, so its paths are the host's paths.
        let top = RemoteHost.of(root)?.path ?? root, file = inside.map { top + "/" + $0 } ?? path
        let vars = [
            "file": file, "relativeFile": relative, "dir": (file as NSString).deletingLastPathComponent,
            "line": String(line), "symbol": symbol, "workspace": top
        ]
        return ShellTemplate.fill(template) { vars[$0] }
    }

    /// Runs Format Document. The text goes to the language's `format` command on stdin and comes back formatted, as one
    /// undoable edit with the cursor kept on its line. A failure shows the first lines of the command's error.
    func format() async {
        guard !remote else {
            NSSound.beep()
            return
        }   // the formatter would run on this Mac, not on the host
        guard let cmd = await command("format"), let editor else { return }
        guard LSPManager.of(app).askTrust(root, again: true, { [weak self] in Task { await self?.format() } })
        else { return }   // the formatter may be the repo's own code, so it needs trust
        let text = editor.text, line = editor.cursor?.line ?? 1
        let result = await Shell.run(app, cmd, cwd: url.deletingLastPathComponent().path, input: text, timeout: 20)
        guard result.code == 0 else {
            let why = (result.stderr.isEmpty ? result.stdout : result.stderr).split(separator: "\n").prefix(2).joined(
                separator: "\n")
            Banner.show(String(localized: "Couldn’t format \(title): \(why)"), style: .error)
            return
        }
        guard editor.text == text, result.stdout != text, !result.stdout.isEmpty || text.isEmpty else { return }   // typed meanwhile, or nothing to do
        editor.apply(text: result.stdout, selection: NSRange(location: 0, length: 0))
        editor.goTo(line: line)
    }
}
