import AppKit
import Core
import DesignKit
import EditorKit
import WorkbenchKit
import KelpKit

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
    private var autosave: Bool { app.settings.bool("editor.autoSave") == true }
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
    private let remote: Bool
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
    var icon: NSImage? { gone ? .symbol("exclamationmark.triangle", String(localized: "Moved or deleted")) : app.fileIcons.image(url.lastPathComponent) }
    var toolTip: String? { gone ? String(localized: "\(path) was moved or deleted. ⌘S asks before writing it there again.") : path }

    init(uri: String, app: AppModel) {
        self.app = app; version = Watched(.file, in: app)
        let (p, line) = TabURI.filePath(uri)
        path = p
        url = URL(fileURLWithPath: p)
        pendingLine = line
        root = ChangeBars.project(of: p, in: app.worktrees)?.worktree.path ?? url.deletingLastPathComponent().path
        let host = RemoteHost.containing(p)?.remote.host
        remote = host != nil
        if !remote, Preview.canPreview(url) { view = Preview.view(for: url, app: app); return }
        if !remote, url.pathExtension.lowercased() == "ipynb" {
            let nb = NotebookTab(app: app, url: url, path: p, worktreeId: ChangeBars.project(of: p, in: app.worktrees)?.worktree.id)
            notebook = nb
            view = nb.view
            return
        }
        // Off the main thread, by the daemon: only a regular file (a pipe or /dev/zero would block or never end), up to
        // `openLimit` (a 300 MB log would hang the window), as UTF-8; a remote project's on its host. A host's image or
        // PDF is copied here instead: Quick Look and PDFKit read a file.
        let box = EditorBox(); view = box
        let wait = host.map { Self.message(String(localized: "Reading it from \($0)…"), failed: false) }
        if let wait { box.pin(wait) }
        let copied = remote && Preview.canPreview(url)
        loading = Task { [weak self] in
            let read: Result<FilesRead.Result, Error>
            do {
                if copied {
                    let copy = URL(fileURLWithPath: try await app.get(FilesFetch(path: p)))
                    guard let self else { return }
                    wait?.removeFromSuperview()
                    let v = Preview.view(for: copy, app: app)
                    preview = v; box.pin(v)
                    if focusWhenLoaded { focus() }
                    return
                }
                read = .success(try await app.get(FilesRead(path: p)))
            } catch { read = .failure(error) }
            guard let self else { return }
            wait?.removeFromSuperview()
            switch read {
            case .success(let f): loaded(f, in: box)
            // Moved or deleted (often by an agent) since the tab was opened: say so, never an empty buffer ⌘S would write.
            case .failure(let e as RPCError) where e.code == RPCError.invalidParams("").code && Unopenable(e) == nil:
                box.pin(Self.message(String(localized: "File not found — it was moved or deleted.")))
            case .failure(let e): box.pin(Self.message(Unopenable(e).map(Self.reason) ?? AppModel.message(e)))
            }
        }
    }

    /// Its text is here: the editor (Markdown with its preview, or code with a status bar), its language server, and its
    /// version followed from then on.
    private func loaded(_ f: FilesRead.Result, in box: NSView) {
        let app = self.app
        let found = ChangeBars.project(of: path, in: app.worktrees)
        root = found?.worktree.path ?? root   // the workspaces may have come in since
        let inside = found.map { $0.worktree.path + "/" + $0.file } ?? path   // as its project names it, not through a symlink
        let text = f.text
        let editable = CodeEditor.canEdit(text)
        if !editable { Banner.show(String(localized: "\(title) opens read only: it's too large, or its lines too long, to edit here.")) }
        let e = CodeEditor(text: text, url: url, editable: editable)
        e.view.clipsToBounds = true
        editor = e
        lastSaved = text
        known = (f.stamp, text)
        let bar = EditorStatusBar(url: url, text: text)
        bar.contextMenu = { [app, weak e] in EditorStatusBar.menu(app, language: e?.languageId) }
        bar.show(cursor: e.cursor)
        bar.onWrap = { [app] in app.extensions.run("editor.toggleWordWrap") }
        bar.onProblems = { [app] in app.extensions.run("files.showProblems") }
        statusBar = bar
        let crumbs = Breadcrumbs(app: app, path: inside, root: root, editor: e)
        let language = e.languageId
        // Each its own: its language may say otherwise than the setting for all files, and a change to either shows at once.
        track(owner: self) { app.settings.bool("editor.wordWrap", language: language) ?? false } changed: { [weak e, weak bar] wraps in
            e?.wrapsHere = wraps
            e?.refreshAppearance()
            bar?.show(wrapping: wraps)
        }
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) || ArtifactBar.isPage(path) {   // an agent's page of HTML too
            let md = MarkdownTab(editor: e, url: url, app: app)
            md.startInPreview = path == Help.location.path || ArtifactBar.isPage(path)   // the help and agents' pages are for reading
            md.onEditing = { [weak bar] in bar?.editing = $0 }
            md.saveFile = { [weak self] in await self?.save() ?? false }; md.onPageTitle = { [weak self] in self?.pageTitle = $0 }
            markdown = md; box.pin(stacked(md.header(else: crumbs), md.view, bar))
        } else {
            box.pin(stacked(crumbs, e.view, bar))
        }
        let before = e.onSelection   // Markdown's selection bar follows the selection too
        e.onSelection = { [weak bar, weak e] in
            before?()
            bar?.show(cursor: e?.cursor)
            bar?.show(problem: e?.problemAtCursor?.message)
        }
        e.onChange = { [weak self] t in self?.edited(t) }
        if let kept = backup.text {   // what a crash left
            if kept == text { backup.drop() } else { e.setText(kept); edited(kept) }
        }
        e.contextMenu = { [weak self] m in self?.contextMenu(m) }
        track(owner: self) { app.themes.editorRevision } changed: { [weak self] _ in
            self?.editor?.refreshAppearance()
            self?.markdown?.themeChanged()
        }
        if focusWhenLoaded { focus() }
        rules = FileRules(app: app, path: inside, root: root, editor: e, bar: bar)
        track(owner: self) { [app] in app.worktrees.map(\.path) } changed: { [weak self] _ in self?.followProject() }
        guard !remote else { return }   // a host's file: no events (nothing pushes them), no language server here
        bar.onTrust = { [weak self] in Task { [weak self] in guard let self else { return }; await app.lsp.trust(app, root) } }
        track(owner: self) { [weak self] in self.map { app.lsp.restricts(app, $0.root, $0.language) } ?? false }
            changed: { [weak bar] in bar?.show(restricted: $0) }
        let p = path
        version.key = p
        track(owner: self) { [app] in app.fileVersions[p] } changed: { [weak self] _ in self?.diskChanged() }
        startLSP()
        track(owner: self) { [app] in app.connections } changed: { [weak self] now in
            guard let self, let was = lspOpenedOn, was != now else { return }
            lspOpenedOn = nil; startLSP()
        }
    }
    isolated deinit {
        // Dropped without close() (its workspace went away): autosave writes what's safe to write, never over a conflict
        // (the daemon writes only over the version last read or written here). Sent now: nothing may hold the tab once
        // it's gone (a save on its way holds it, so none is).
        if autosave, !discarded, let e = editor, FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) == .write {
            let write = FilesWrite(path: path, text: e.text, base: known?.stamp)
            Task { [app] in await app.call(write) }
        }
        if lspOpenedOn != nil { app.lsp.close(app, root: root, path: path) }
    }

    func focus() {
        guard let editor else {
            // A preview (an image, a PDF) takes the keys itself, so ⌘C copies from it.
            let v = preview ?? view
            if v.acceptsFirstResponder { v.window?.makeFirstResponder(v) } else { focusWhenLoaded = true }
            return
        }
        editor.focus()
        if let l = pendingLine { pendingLine = nil; DispatchQueue.main.async { [weak self] in self?.editor?.goTo(line: l) } }
    }
    func goTo(line: Int) {
        guard let editor else { // still being read: once it's here
            pendingLine = line
            focusWhenLoaded = true
            return
        }
        editor.goTo(line: line); editor.focus()
    }
    // MARK: saving

    private func edited(_ t: String) {
        edits += 1
        backup.keep(t)
        if autosave { autosaving.after(0.6) { [weak self] in Task { await self?.autosaveNow() } } }
        editedStateMayHaveChanged()
        markdown?.textChanged()
        guard lspOpenedOn != nil else { return }   // no language server for it (or for a file on another machine)
        lspTask?.cancel()
        lspUnsent = t
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
            guard let e = editor else { return true }
            switch FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) {
            case .write: if await write() { return true }; return gone ? await askToWriteBack() : false
            case .conflict: apply(disk); return false   // don't clobber an agent's edit: ask
            case .missing: return await askToWriteBack()
            default: return true
            }
        }
    }

    /// Moved or deleted (git mv, a rename): writing would bring the old file back beside the new one, so it asks.
    private func askToWriteBack() async -> Bool {
        let a = NSAlert(); a.messageText = String(localized: "“\(title)” was moved or deleted")
        a.informativeText = String(localized: "Save writes it at its old place again.")
        a.addButton(withTitle: String(localized: "Save Here")); a.addButton(withTitle: String(localized: "Cancel"))
        guard await runSheet(a) == .alertFirstButtonReturn else { return false }
        return await write(overAnything: true)
    }

    /// Autosave writes only when that's safe; a conflict asks (if the tab is on screen), a missing file waits for ⌘S.
    private func autosaveNow() async {
        _ = await serially { [self] in
            guard let e = editor else { return true }
            switch FileSync.save(buffer: e.text, saved: lastSaved, disk: disk) {
            case .write: return await write()
            case .conflict: apply(disk); return false
            default: return true
            }
        }
    }

    /// Saves go one at a time, each checked against what the one before wrote, not what's on its way. The task holds
    /// the tab: one closed (or its workspace) right after Save still gets written.
    private func serially(_ save: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = saving
        let next = Task { _ = await previous?.value; return await save() }
        saving = next
        return await next.value
    }

    /// The buffer to the file, by the daemon (atomically, through a symlink to the file it points at), only over the version
    /// last read or written here; `overAnything`: whatever is there (Save Here). Changed meanwhile: asked about, unless
    /// only touched (its text still what this tab last saved), which is written over once. Only through `serially`.
    private func write(overAnything: Bool = false, touched: Bool = false) async -> Bool {
        guard let e = editor else { return true }
        // A Swift string, made off the main thread (5 MB took 400 ms on it): the buffer is compared against it on every
        // keystroke, fast only with a Swift string on this side (`FileSync.same`).
        let buffer = e.text, at = edits
        let text = await Task.detached { String(decoding: Data(buffer.utf8), as: UTF8.self) }.value
        writing = true
        let res = await app.tryCall(FilesWrite(path: path, text: text, base: overAnything ? nil : known?.stamp))
        writing = false
        defer { if readAgain { readAgain = false; diskChanged() } }   // its own version pushed, or an agent's right after
        if let error = res.error { Banner.show(String(localized: "Couldn't save \(title): \(error)"), style: .error); return false }
        guard let r = res.value else { return false }
        if let stamp = r.stamp {
            gone = false
            known = (stamp, text)
            saved(text, at: at)
            changeBars?.refresh()
            return true
        }
        if r.missing == true { gone = true; return false }
        guard let c = r.conflict else { return false }
        known = (c.stamp, c.text)
        if !touched, let now = c.text, FileSync.same(now, lastSaved) { return await write(touched: true) }
        apply(.present(c.text))   // an agent's edit: asked about
        return false
    }

    /// Closing with a save: the tab waits until the file has it, and stays (with its edits) when that failed.
    /// `answering`: what the sheet said it does, so a Save that puts a deleted file back or replaces an agent's version does.
    func writeAndClose(answering action: FileSync.Action = .write) async -> Bool { await serially { [self] in await write(overAnything: action != .write) } }

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
        guard editor != nil, let v = app.fileVersions[path] else { return }
        if reading || writing { readAgain = true; return }
        guard let now = v.stamp else { apply(.missing); return }
        if let known, known.stamp == now { return }   // our own write
        reading = true
        let p = path
        Task { [weak self, app] in
            let read: Result<FilesRead.Result, Error>
            do { read = .success(try await app.get(FilesRead(path: p))) } catch { read = .failure(error) }
            guard let self else { return }
            reading = false
            switch read {
            case .success(let f): known = (f.stamp, f.text); apply(.present(f.text))
            case .failure(let e) where Unopenable(e) == .binary: known = (now, nil); apply(.present(nil))   // asked about as such
            case .failure: break   // grown past the limit (a log), a pipe now, or gone (its next version says so): kept as shown
            }
            if readAgain { readAgain = false; diskChanged() }
        }
    }

    private func apply(_ d: FileSync.Disk) {
        guard let e = editor else { return }
        let wasGone = gone
        gone = d == .missing
        switch FileSync.diskChanged(buffer: e.text, saved: lastSaved, disk: d) {
        case .follow(let text):   // no local edits: follow the disk
            e.setText(text)
            saved(text, at: edits)
            markdown?.textChanged()
        case .conflict(let text): askKeepMine(disk: text)
        case .missing where !wasGone && isEdited:
            Banner.show(String(localized: "\(title) was moved or deleted. ⌘S asks before writing it there again."))
        default: break
        }
    }

    private func askKeepMine(disk: String) {
        guard let e = editor, let w = view.window, w.attachedSheet == nil else { return }   // asked again on the next change or ⌘S
        let a = NSAlert(); a.messageText = String(localized: "\(title) changed on disk")
        a.informativeText = String(localized: "An agent edited this file while you had unsaved changes.")
        // No longer text (another encoding, binary): there's no disk version to show, and an empty one would throw the
        // edits away. Keep Mine writes them; Cancel leaves the tab and the file as they are.
        let notText: Bool = if case .present(nil) = self.disk { true } else { false }
        if notText { a.informativeText = String(localized: "The file on disk is no longer text (another encoding, or binary). Keep Mine writes your version over it.") }
        a.addButton(withTitle: String(localized: "Keep Mine"))
        a.addButton(withTitle: notText ? String(localized: "Cancel") : String(localized: "Use Disk Version"))
        // Holds the tab until answered: closing it meanwhile mustn't throw away the user's choice (or their edits).
        a.beginSheetModal(for: w) { r in   // AppKit: on main
            MainActor.assumeIsolated {
                if r == .alertFirstButtonReturn { self.lastSaved = disk; Task { _ = await self.serially { await self.write() } } }
                else if !notText {
                    e.setText(disk)
                    self.saved(disk, at: self.edits)
                    self.markdown?.textChanged()
                }
            }
        }
    }

    // MARK: language commands

    var language: LanguageSpec? { app.lsp.language(app, path) }

    /// The language's `run`, `test` or `format` with this file's variables filled in. Nil when there's none (a beep
    /// for a file of no language, else a banner).
    func command(_ name: String) async -> String? {
        guard let lang = language, editor != nil else { NSSound.beep(); return nil }
        guard let template = lang[command: name] else { Banner.show(String(localized: "\(lang.id) has no “\(name)” command.")); return nil }
        let (line, column) = editor?.cursor ?? (1, 1)
        var symbol = ""
        if template.contains("${symbol}") {
            await lspCaughtUp()
            symbol = await app.lsp.symbol(app, root: root, path: path, line: line) ?? LanguageSpec.word(in: editor?.text ?? "", line: line, column: column)
        }
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let vars = ["file": path, "relativeFile": relative, "dir": url.deletingLastPathComponent().path,
                    "line": String(line), "symbol": symbol, "workspace": root]
        return ShellTemplate.fill(template) { vars[$0] }
    }

    /// Format Document: the text goes to the language's `format` on stdin and comes back formatted, as one undoable
    /// edit with the cursor on its line. A failure shows the command's first lines of error.
    func format() async {
        guard !remote else { NSSound.beep(); return }   // its formatter would run here, not on the host
        guard let cmd = await command("format"), let e = editor else { return }
        guard app.lsp.askTrust(app, root, { [weak self] in Task { await self?.format() } }) else { return }   // its toolchain may be the repo's
        let text = e.text, line = e.cursor?.line ?? 1
        let r = await Shell.run(app, cmd, cwd: url.deletingLastPathComponent().path, input: text, timeout: 20)
        guard r.code == 0 else {
            let why = (r.stderr.isEmpty ? r.stdout : r.stderr).split(separator: "\n").prefix(2).joined(separator: "\n")
            Banner.show(String(localized: "Couldn't format \(title): \(why)"), style: .error); return
        }
        guard e.text == text, r.stdout != text, !r.stdout.isEmpty || text.isEmpty else { return }   // typed meanwhile, or nothing to do
        e.apply(text: r.stdout, selection: NSRange(location: 0, length: 0))
        e.goTo(line: line)
    }

    /// What the tab says instead of the text (the daemon refuses it, here or on a host: `files.read`).
    static func reason(_ u: Unopenable) -> String {
        switch u {
        case .special: String(localized: "Kelp opens files, not devices or pipes.")
        case .tooBig(let n):
            String(localized: "Too big to open here (\(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file))). Open it with another app.")
        case .binary: String(localized: "Binary file — open it with another app.")
        }
    }

    /// Its items in the tab's context menu.
    /// The editor's context menu, after Cut, Copy and Paste.

    static func menu(_ app: AppModel, _ m: NSMenu, uri: String, workspace: String, openBeside: @escaping @MainActor (String) -> Void) {
        let path = TabURI.filePath(uri).path
        m.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path) }
        if ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) {
            m.add(String(localized: "Open Preview to the Side")) { openBeside("preview:" + path) }
        }
        m.addItem(.separator())
        WorkspaceActions.addLocate(to: m, path: path, copies: [(String(localized: "Web Link"), { @MainActor in FileActions(app).copyWebLink(path) })])
    }

    /// What the tab shows instead of the file: the empty state, a warning when it couldn't be opened.
    private static func message(_ s: String, failed: Bool = true) -> NSView {
        let v = NSView(), e = EmptyStateView()
        e.place(in: v)
        if failed { e.showError(s, text: nil) } else { e.show(s, symbol: "icloud.and.arrow.down") }
        return v
    }
}

// MARK: its project and language server
extension FileTab {
    /// The workspaces changed (or weren't known yet when the tab opened): the change bars and the language server follow
    /// the file's project.
    private func followProject() {
        guard let e = editor, let found = ChangeBars.project(of: path, in: app.worktrees), changeBars == nil || found.worktree.path != root
        else { return }
        changeBars = ChangeBars(app: app, worktree: found.worktree, file: found.file, editor: e) { [weak self] in self?.isEdited == true }
        guard found.worktree.path != root else { return }   // its first bars: the project is the one it had
        if lspOpenedOn != nil { app.lsp.close(app, root: root, path: path); lspOpenedOn = nil }
        root = found.worktree.path; if !remote { startLSP() }
    }

    private func startLSP() {
        let p = path, r = root, app = app
        guard app.lsp.language(app, p)?.server != nil,
              app.lsp.whenTrusted(app, r, { [weak self] in self?.startLSP() }) else { return }   // asked once per project
        Task { [weak self] in
            guard let text = self?.editor?.text, await app.lsp.open(app, root: r, path: p, text: text, retry: { [weak self] in self?.startLSP() }),
                  let self, let e = editor else { return }
            lspOpenedOn = app.connections
            connectServer(to: e, root: r, path: p)
        }
    }

    /// LSP: definition of the symbol at the cursor, opened as a tab.
    func jumpToDefinition() {
        guard let e = editor, let (l, c) = e.cursor else { return }
        let p = path, r = root, app = app
        Task {
            await lspCaughtUp()
            guard let loc = await app.lsp.definition(app, root: r, path: p, line: l, column: c) else { NSSound.beep(); return }
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
        guard let e = editor, isEdited else { return true }
        let action = FileSync.save(buffer: e.text, saved: lastSaved, disk: disk)
        if autosave, action == .write, await writeAndClose() { return true }
        let a = NSAlert(); a.messageText = String(localized: "Do you want to save the changes you made to “\(title)”?")
        a.informativeText = switch action {
        case .conflict: String(localized: "An agent changed it on disk meanwhile. Save replaces that version with yours.")
        case .missing: String(localized: "It was moved or deleted. Save writes it at its old place again.")
        default: String(localized: "Your changes will be lost if you don't save them.")
        }
        a.addButton(withTitle: String(localized: "Save"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.addButton(withTitle: String(localized: "Don't Save"))
        switch await runSheet(a) {
        case .alertFirstButtonReturn: return await writeAndClose(answering: action)
        case .alertThirdButtonReturn:
            discard()
            return true
        default: return false
        }
    }
}
