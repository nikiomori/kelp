import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// A file as a tab: code editor with LSP, Markdown with preview, notebooks, or a Quick Look preview.
/// Like a Mac document: edits show as a dot on the tab and the window's close button, ⌘S saves, closing asks
/// (Settings › Editor › Save automatically turns autosave on). Agents edit files on disk too: unchanged buffers
/// follow the disk; conflicting edits ask. The daemon reads and writes it (here or on a remote project's host) and says
/// when its version changes (`WatchTopic.file`); the tab touches no file itself.
@MainActor @Observable
final class FileTab: SavableTab {
    let path: String, url: URL
    let app: AppModel
    let view: NSView
    private(set) var editor: CodeEditor?
    private(set) var markdown: MarkdownTab?
    /// A page an agent made is named by its title, not "doc.md".
    private var pageTitle: String?
    private var notebook: NotebookTab?
    private var changeBars: ChangeBars?
    /// Its indentation and what Save tidies.
    private(set) var rules: FileRules?
    weak var statusBar: EditorStatusBar?
    /// What the file was last read or written as; a compare against the one before is moot.
    private var lastSaved = "" { didSet { comparing?.cancel() } }
    private(set) var isEdited = false
    /// Keystrokes so far: a save knows whether the buffer is still the text it wrote.
    private var edits = 0
    private var comparing: Task<Void, Never>?
    private var autosave: Bool { app.settings[SettingKeys.autoSave] }
    private let autosaving = Debounce()
    var lspTask: Task<Void, Never>?
    /// Typed and not sent to the language server yet (changes go a moment after the last key).
    var lspUnsent: String?
    /// The connection (`AppModel.connections`) its language server was given this file on; nil when it has none. A new
    /// daemon knows nothing of it: the file is given again.
    private var lspOpenedOn: Int?
    /// Its version as the daemon pushes it (`AppModel.fileVersions`), while the tab is open.
    private let version: Watched
    /// Its project's folder (the file's own folder outside every project); followed as the workspaces change.
    private(set) var root: String
    /// A remote project's file: no language server, formatter or notebook for it here; its preview shows a copy.
    let remote: Bool
    /// A remote image's or PDF's preview, once its copy is here.
    private var preview: NSView?
    private var pendingLine: Int?
    /// Closed with Don't Save: deinit's autosave mustn't write it after all.
    private var discarded = false
    func discard() {
        discarded = true
        comparing?.cancel()
        isEdited = false
        backup.drop()
    }
    @ObservationIgnored private lazy var backup = UnsavedBackup(app: app, uri: uri)
    /// The file was moved or deleted under the tab (often by an agent): the tab says so, ⌘S asks before writing it back.
    var gone = false
    /// The last save (each waits for the one before) and whether it wrote; `writing` while one is on its way to disk.
    private var saving: Task<Bool, Never>?
    private var writing = false
    /// Focused while its text was still on the way: focused (and its line shown) once it's here.
    private var focusWhenLoaded = false
    /// The first read (tests wait for it).
    private(set) var loading: Task<Void, Never>?

    var uri: String { TabURI.file(path) }
    var fileURL: URL? { url }
    var title: String { pageTitle ?? url.lastPathComponent }
    var icon: NSImage? {
        gone
            ? .symbol("exclamationmark.triangle", String(localized: "Moved or deleted"))
            : app.fileIcons.image(url.lastPathComponent)
    }
    var toolTip: String? {
        gone ? String(localized: "\(path) was moved or deleted. ⌘S asks before writing it there again.") : path
    }

    init(uri: String, app: AppModel) {
        self.app = app
        version = Watched(.file, in: app)
        let (filePath, line) = TabURI.filePath(uri)
        path = filePath
        url = URL(fileURLWithPath: filePath)
        pendingLine = line
        root =
            ChangeBars.project(of: filePath, in: app.worktrees)?.worktree.path ?? url.deletingLastPathComponent().path
        let host = RemoteHost.containing(filePath)?.remote.host
        remote = host != nil
        if !remote, Preview.canPreview(url) {
            view = Preview.view(for: url, app: app)
            return
        }
        if !remote, url.pathExtension.lowercased() == "ipynb" {
            let nb = NotebookTab(
                app: app, url: url, path: filePath,
                worktreeId: ChangeBars.project(of: filePath, in: app.worktrees)?.worktree.id)
            notebook = nb
            view = nb.view
            return
        }
        // Off the main thread, by the daemon: only a regular file (a pipe or /dev/zero would block or never end), up to
        // `openLimit` (a 300 MB log would hang the window), as UTF-8; a remote project's on its host. A host's image or
        // PDF is copied here instead: Quick Look and PDFKit read a file.
        let box = EditorBox()
        view = box
        let wait = host.map { Self.message(String(localized: "Reading it from \($0)…"), failed: false) }
        if let wait { box.pin(wait) }
        let copied = remote && Preview.canPreview(url)
        loading = Task { [weak self] in
            let read: Result<FilesRead.Result, Error>
            do {
                if copied {
                    let copy = URL(fileURLWithPath: try await app.get(FilesFetch(path: filePath)))
                    guard let self else { return }
                    wait?.removeFromSuperview()
                    let previewView = Preview.view(for: copy, app: app)
                    preview = previewView
                    box.pin(previewView)
                    if focusWhenLoaded { focus() }
                    return
                }
                read = .success(try await app.get(FilesRead(path: filePath)))
            } catch { read = .failure(error) }
            guard let self else { return }
            wait?.removeFromSuperview()
            switch read {
            case .success(let file): loaded(file, in: box)
            // Moved or deleted (often by an agent) since the tab was opened: say so, never an empty buffer ⌘S would write.
            case .failure(let error as RPCError)
            where error.code == RPCError.invalidParams("").code && Unopenable(error) == nil:
                box.pin(missing())
            case .failure(let error):
                box.pin(Self.message(Unopenable(error).map(Self.reason) ?? AppModel.message(error)))
            }
        }
    }

    /// Its text is here: the editor (Markdown with its preview, or code with a status bar), its language server, and its
    /// version followed from then on.
    private func loaded(_ file: FilesRead.Result, in box: NSView) {
        let app = self.app
        let found = ChangeBars.project(of: path, in: app.worktrees)
        root = found?.worktree.path ?? root   // the workspaces may have come in since
        let inside = found.map { $0.worktree.path + "/" + $0.file } ?? path   // as its project names it, not through a symlink
        let text = file.text
        let editable = CodeEditor.canEdit(text)
        if !editable {
            Banner.show(
                String(localized: "\(title) opens read only: it's too large, or its lines too long, to edit here."))
        }
        let codeEditor = CodeEditor(text: text, url: url, editable: editable)
        codeEditor.view.clipsToBounds = true
        editor = codeEditor
        lastSaved = text
        known = (file.stamp, text)
        let bar = EditorStatusBar(url: url, text: text)
        bar.contextMenu = { [app, weak codeEditor] in EditorStatusBar.menu(app, language: codeEditor?.languageId) }
        bar.show(cursor: codeEditor.cursor)
        bar.onWrap = { [app] in app.extensions.run("editor.toggleWordWrap") }
        bar.onProblems = { [app] in app.extensions.run("files.showProblems") }
        statusBar = bar
        let crumbs = Breadcrumbs(app: app, path: inside, root: root, editor: codeEditor)
        let language = codeEditor.languageId
        // Each its own: its language may say otherwise than the setting for all files, and a change to either shows at once.
        track(owner: self) {
            app.settings[SettingKeys.wordWrap, language: language]
        } changed: { [weak codeEditor, weak bar] wraps in
            codeEditor?.wrapsHere = wraps
            codeEditor?.refreshAppearance()
            bar?.show(wrapping: wraps)
        }
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) || ArtifactBar.isPage(path) {   // an agent's page of HTML too
            let md = MarkdownTab(editor: codeEditor, url: url, app: app)
            md.startInPreview = path == Help.location.path || ArtifactBar.isPage(path)   // the help and agents' pages are for reading
            md.saveFile = { [weak self] in await self?.save() ?? false }
            md.onPageTitle = { [weak self] in self?.pageTitle = $0 }
            markdown = md
            box.pin(stacked(md.header(else: crumbs), md.view, bar))
            md.attach(bar)
        } else {
            box.pin(stacked(withTrustBar(crumbs), codeEditor.view, bar))
        }
        let before = codeEditor.onSelection   // Markdown's selection bar follows the selection too
        codeEditor.onSelection = { [weak bar, weak codeEditor] in
            before?()
            bar?.show(cursor: codeEditor?.cursor)
            bar?.show(problem: codeEditor?.problemAtCursor?.message)
        }
        codeEditor.onChange = { [weak self] t in self?.edited(t) }
        if let kept = backup.text {   // what a crash left
            if kept == text {
                backup.drop()
            } else {
                codeEditor.setText(kept)
                edited(kept)
            }
        }
        codeEditor.contextMenu = { [weak self] m in self?.contextMenu(m) }
        track(owner: self) {
            app.themes.editorRevision
        } changed: { [weak self] _ in
            self?.editor?.refreshAppearance()
            self?.markdown?.themeChanged()
        }
        if focusWhenLoaded { focus() }
        rules = FileRules(app: app, path: inside, root: root, editor: codeEditor, bar: bar)
        track(owner: self) { [app] in
            app.worktrees.map(\.path)
        } changed: { [weak self] _ in
            self?.followProject()
        }
        guard !remote else { return }   // a host's file: no events (nothing pushes them), no language server here
        bar.onTrust = { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                await LSPManager.of(app).trust(app, root)
            }
        }
        track(owner: self) { [weak self] in
            self.map { LSPManager.of(app).restricts(app, $0.root, $0.language) } ?? false
        } changed: { [weak bar] in
            bar?.show(restricted: $0)
        }
        let filePath = path
        version.key = filePath
        track(owner: self) { [app] in
            app.latest(FileEvent.self, filePath)
        } changed: { [weak self] _ in
            self?.diskChanged()
        }
        startLSP()
        track(owner: self) { [app] in
            app.connections
        } changed: { [weak self] now in
            guard let self, let was = lspOpenedOn, was != now else { return }
            lspOpenedOn = nil
            startLSP()
        }
    }
    isolated deinit {
        // Dropped without close() (its workspace went away and its save failed): autosave writes what's safe to write, never
        // over a conflict (the daemon writes only over the version last read or written here). Sent now: nothing may hold
        // the tab once it's gone (a save on its way holds it, so none is). Either way the backup keeps the text
        // (`UnsavedBackup`'s deinit) until a workspace holding the file takes it back.
        if autosave, !discarded, let editor, FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk) == .write
        {
            let write = FilesWrite(path: path, text: editor.text, base: known?.stamp)
            Task { [app] in await app.call(write) }
        }
        if lspOpenedOn != nil { LSPManager.of(app).close(app, root: root, path: path) }
    }

    func focus() {
        guard let editor else {
            // A preview (an image, a PDF) takes the keys itself, so ⌘C copies from it.
            let shown = preview ?? view
            if shown.acceptsFirstResponder { shown.window?.makeFirstResponder(shown) } else { focusWhenLoaded = true }
            return
        }
        editor.focus()
        if let line = pendingLine {
            pendingLine = nil
            DispatchQueue.main.async { [weak self] in self?.editor?.goTo(line: line) }
        }
    }
    func goTo(line: Int) {
        guard let editor else {   // still being read: once it's here
            pendingLine = line
            focusWhenLoaded = true
            return
        }
        editor.goTo(line: line)
        editor.focus()
    }
    // MARK: saving

    private func edited(_ text: String) {
        edits += 1
        backup.keep(text)
        if autosave { autosaving.after(0.6) { [weak self] in Task { await self?.autosaveNow() } } }
        editedStateMayHaveChanged()
        markdown?.textChanged()
        guard lspOpenedOn != nil else { return }   // no language server for it (or for a file on another machine)
        lspTask?.cancel()
        lspUnsent = text
        lspTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.sendUnsent()
        }
    }

    /// The file as the daemon last gave or pushed it: gone, or its text as last read or written here (nil: not UTF-8).
    /// Kept current by its version (`diskChanged`), so a save's check reads nothing; the daemon then writes only over
    /// that version, so a change it hasn't heard of yet is still never written over.
    private var disk: FileSync.Disk { gone ? .missing : .present(known?.text) }
    /// What was last read or written, and its version.
    private var known: (stamp: FileStamp, text: String?)?
    private var reading = false
    private var readAgain = false

    /// ⌘S. False when it couldn't be written, or the user is asked first (an agent changed the file meanwhile, or it's gone).
    @discardableResult
    func save() async -> Bool {
        guard editor != nil else { return true }
        return await serially { [self] in
            guard let editor else { return true }
            switch FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk) {
            case .write:
                if await write() { return true }
                return gone ? await askToWriteBack() : false
            case .conflict:
                apply(disk)
                return false   // don't clobber an agent's edit: ask
            case .missing: return await askToWriteBack()
            default: return true
            }
        }
    }

    /// Moved or deleted (git mv, a rename): writing would bring the old file back beside the new one, so it asks.
    private func askToWriteBack() async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(title)” was moved or deleted")
        alert.informativeText = String(localized: "Save writes it at its old place again.")
        alert.addButton(withTitle: String(localized: "Save Here"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await runSheet(alert) == .alertFirstButtonReturn else { return false }
        return await write(overAnything: true)
    }

    /// Autosave writes only when that's safe; a conflict asks (if the tab is on screen), a missing file waits for ⌘S.
    private func autosaveNow() async {
        _ = await serially { [self] in
            guard let editor else { return true }
            switch FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk) {
            case .write: return await write()
            case .conflict:
                apply(disk)
                return false
            default: return true
            }
        }
    }

    /// Saves go one at a time, each checked against what the one before wrote, not what's on its way. The task holds
    /// the tab: one closed (or its workspace) right after Save still gets written.
    private func serially(_ save: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = saving
        let next = Task {
            _ = await previous?.value
            return await save()
        }
        saving = next
        return await next.value
    }

    /// The buffer to the file, by the daemon (atomically, through a symlink to the file it points at), only over the version
    /// last read or written here; `overAnything`: whatever is there (Save Here). Changed meanwhile: asked about, unless
    /// only touched (its text still what this tab last saved), which is written over once. Only through `serially`.
    private func write(overAnything: Bool = false, touched: Bool = false) async -> Bool {
        guard let editor else { return true }
        // A Swift string, made off the main thread (5 MB took 400 ms on it): the buffer is compared against it on every
        // keystroke, fast only with a Swift string on this side (`FileSync.same`).
        let buffer = editor.text, at = edits
        let text = await Task.detached { String(decoding: Data(buffer.utf8), as: UTF8.self) }.value
        writing = true
        let res = await app.tryCall(FilesWrite(path: path, text: text, base: overAnything ? nil : known?.stamp))
        writing = false
        defer {
            if readAgain {
                readAgain = false
                diskChanged()
            }
        }   // its own version pushed, or an agent's right after
        if let error = res.error {
            Banner.show(String(localized: "Couldn't save \(title): \(error)"), style: .error)
            return false
        }
        guard let written = res.value else { return false }
        if let stamp = written.stamp {
            gone = false
            known = (stamp, text)
            saved(text, at: at)
            changeBars?.refresh()
            return true
        }
        if written.missing == true {
            gone = true
            return false
        }
        guard let conflict = written.conflict else { return false }
        known = (conflict.stamp, conflict.text)
        if !touched, let now = conflict.text, FileSync.same(now, lastSaved) { return await write(touched: true) }
        apply(.present(conflict.text))   // an agent's edit: asked about
        return false
    }

    /// Closing with a save: the tab waits until the file has it, and stays (with its edits) when that failed.
    /// `answering`: what the sheet said it does, so a Save that puts a deleted file back or replaces an agent's version does.
    func writeAndClose(answering action: FileSync.Action = .write) async -> Bool {
        await serially { [self] in await write(overAnything: action != .write) }
    }

    var pendingSave: Task<Void, Never>? { saving.map { s in Task { _ = await s.value } } }

    /// The file is `text` now (written or taken from disk), and the buffer was it `at` that many keystrokes: still is, or
    /// it's compared.
    private func saved(_ text: String, at: Int) {
        lastSaved = text
        if at == edits { setEdited(false) } else { editedStateMayHaveChanged() }
    }

    /// After a keystroke. Most change the buffer's length, which tells at once; one that doesn't (a letter typed over, an
    /// undo back to the saved text) is compared, off the main thread for a big file (33 ms for 5 MB). Edited meanwhile:
    /// a quit right then still asks.
    private func editedStateMayHaveChanged() {
        comparing?.cancel()
        guard let text = editor?.text else { return setEdited(false) }
        let length = text.utf16.count
        guard length == lastSaved.utf16.count else { return setEdited(true) }
        guard length > 100_000 else { return setEdited(!FileSync.same(text, lastSaved)) }
        setEdited(true)
        let saved = lastSaved
        comparing = Task {
            let same = await Task.detached { FileSync.same(text, saved) }.value
            if !Task.isCancelled { setEdited(!same) }
        }
    }

    private func setEdited(_ now: Bool) {
        if now != isEdited { isEdited = now }
        if !now { backup.drop() }
    }

    /// A new version pushed (`WatchTopic.file`): read again only one this tab didn't read or write itself (a log a dev
    /// server appends to changes every quarter second). One read at a time; versions meanwhile make one more, as do
    /// versions while a save writes the file.

    private func diskChanged() {
        changeBars?.refresh()
        showProblems()
        guard editor != nil, let event = app.latest(FileEvent.self, path) else { return }
        if reading || writing {
            readAgain = true
            return
        }
        guard let now = event.stamp else {
            apply(.missing)
            return
        }
        if let known, known.stamp == now { return }   // our own write
        reading = true
        let filePath = path
        Task { [weak self, app] in
            let read: Result<FilesRead.Result, Error>
            do { read = .success(try await app.get(FilesRead(path: filePath))) } catch { read = .failure(error) }
            guard let self else { return }
            reading = false
            switch read {
            case .success(let file):
                known = (file.stamp, file.text)
                apply(.present(file.text))
            case .failure(let error) where Unopenable(error) == .binary:
                known = (now, nil)
                apply(.present(nil))   // asked about as such
            case .failure: break   // grown past the limit (a log), a pipe now, or gone (its next version says so): kept as shown
            }
            if readAgain {
                readAgain = false
                diskChanged()
            }
        }
    }

    private func apply(_ onDisk: FileSync.Disk) {
        guard let editor else { return }
        let wasGone = gone
        gone = onDisk == .missing
        switch FileSync.diskChanged(buffer: editor.text, saved: lastSaved, disk: onDisk) {
        case .follow(let text):   // no local edits: follow the disk
            editor.setText(text)
            saved(text, at: edits)
            markdown?.textChanged()
        case .conflict(let text): askKeepMine(disk: text)
        case .missing where !wasGone && isEdited:
            Banner.show(String(localized: "\(title) was moved or deleted. ⌘S asks before writing it there again."))
        default: break
        }
    }

    private func askKeepMine(disk: String) {
        guard let editor, let window = view.window, window.attachedSheet == nil else { return }   // asked again on the next change or ⌘S
        let alert = NSAlert()
        alert.messageText = String(localized: "\(title) changed on disk")
        alert.informativeText = String(localized: "An agent edited this file while you had unsaved changes.")
        // No longer text (another encoding, binary): there's no disk version to show, and an empty one would throw the
        // edits away. Keep Mine writes them; Cancel leaves the tab and the file as they are.
        let notText: Bool = if case .present(nil) = self.disk { true } else { false }
        if notText {
            alert.informativeText = String(
                localized:
                    "The file on disk is no longer text (another encoding, or binary). Keep Mine writes your version over it."
            )
        }
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        alert.addButton(withTitle: notText ? String(localized: "Cancel") : String(localized: "Use Disk Version"))
        // Holds the tab until answered: closing it meanwhile mustn't throw away the user's choice (or their edits).
        alert.beginSheetModal(for: window) { response in   // AppKit: on main
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn {
                    self.lastSaved = disk
                    Task { _ = await self.serially { await self.write() } }
                } else if !notText {
                    editor.setText(disk)
                    self.saved(disk, at: self.edits)
                    self.markdown?.textChanged()
                }
            }
        }
    }

    // MARK: language commands

    var language: LanguageSpec? { LSPManager.of(app).language(app, path) }

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
                await LSPManager.of(app).symbol(app, root: root, path: path, line: line)
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
        guard LSPManager.of(app).askTrust(app, root, again: true, { [weak self] in Task { await self?.format() } })
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

    /// What the tab says instead of the text (the daemon refuses it, here or on a host: `files.read`).
    static func reason(_ unopenable: Unopenable) -> String {
        switch unopenable {
        case .special: String(localized: "Kelp opens files, not devices or pipes.")
        case .tooBig(let size):
            String(
                localized:
                    "Too big to open here (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))). Open it with another app."
            )
        case .binary: String(localized: "Binary file — open it with another app.")
        }
    }

    /// Its items in the tab's context menu.
    /// The editor's context menu, after Cut, Copy and Paste.

    static func menu(
        _ app: AppModel, _ menu: NSMenu, uri: String, workspace: String,
        openBeside: @escaping @MainActor (String) -> Void
    ) {
        let path = TabURI.filePath(uri).path
        menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path) }
        if ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) {
            menu.add(String(localized: "Open Preview to the Side")) { openBeside("preview:" + path) }
        }
        menu.addItem(.separator())
        WorkspaceActions.addLocate(
            to: menu, path: path,
            copies: [(String(localized: "Web Link"), { @MainActor in FileActions(app).copyWebLink(path) })])
    }

    /// What the tab shows instead of the file: the empty state, a warning when it couldn't be opened.

    private static func message(_ text: String, failed: Bool = true) -> NSView {
        let container = NSView(), empty = EmptyStateView()
        empty.place(in: container)
        if failed { empty.showError(text, text: nil) } else { empty.show(text, symbol: "icloud.and.arrow.down") }
        return container
    }
}

// MARK: its project and language server
extension FileTab {
    /// The workspaces changed (or weren't known yet when the tab opened): the change bars and the language server follow
    /// the file's project.
    private func followProject() {
        guard let editor, let found = ChangeBars.project(of: path, in: app.worktrees),
            changeBars == nil || found.worktree.path != root
        else { return }
        changeBars = ChangeBars(app: app, worktree: found.worktree, file: found.file, editor: editor) { [weak self] in
            self?.isEdited == true
        }
        guard found.worktree.path != root else { return }   // its first bars: the project is the one it had
        if lspOpenedOn != nil {
            LSPManager.of(app).close(app, root: root, path: path)
            lspOpenedOn = nil
        }
        root = found.worktree.path
        if !remote { startLSP() }
    }

    private func startLSP() {
        let filePath = path, projectRoot = root, app = app
        guard LSPManager.of(app).language(app, filePath)?.server != nil,
            LSPManager.of(app).whenTrusted(app, projectRoot, { [weak self] in self?.startLSP() })
        else { return }   // asked once per project
        Task { [weak self] in
            guard let text = self?.editor?.text,
                await LSPManager.of(app).open(
                    app, root: projectRoot, path: filePath, text: text, retry: { [weak self] in self?.startLSP() }),
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
                    app, root: projectRoot, path: filePath, line: line, column: column)
            else {
                NSSound.beep()
                return
            }
            app.workbench.open(TabURI.file(loc.path, line: loc.line))
        }
    }
}

extension FileTab {
    /// Asks about unsaved changes in a sheet, like any Mac document: Save, Don't Save, or keep the tab. With autosave
    /// it only asks when writing isn't safe: an agent changed the file meanwhile, or it was moved or deleted.
    func close() async -> Bool {
        autosaving.cancel()
        _ = await saving?.value   // a save on its way: what's asked is checked against what it wrote
        guard let editor, isEdited else { return true }
        let action = FileSync.save(buffer: editor.text, saved: lastSaved, disk: disk)
        if autosave, action == .write, await writeAndClose() { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?")
        alert.informativeText =
            switch action {
            case .conflict:
                String(localized: "An agent changed it on disk meanwhile. Save replaces that version with yours.")
            case .missing: String(localized: "It was moved or deleted. Save writes it at its old place again.")
            default: String(localized: "Your changes will be lost if you don't save them.")
            }
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        switch await runSheet(alert) {
        case .alertFirstButtonReturn: return await writeAndClose(answering: action)
        case .alertThirdButtonReturn:
            discard()
            return true
        default: return false
        }
    }
}
