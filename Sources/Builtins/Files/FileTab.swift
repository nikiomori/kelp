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
    var changeBars: ChangeBars?
    /// Its indentation and what Save tidies.
    private(set) var rules: FileRules?
    weak var statusBar: EditorStatusBar?
    /// What the file was last read or written as; a compare against the one before is moot.
    var lastSaved = "" { didSet { comparing?.cancel() } }
    var isEdited = false
    /// Keystrokes so far: a save knows whether the buffer is still the text it wrote.
    var edits = 0
    var comparing: Task<Void, Never>?
    var autosave: Bool { app.settings[SettingKeys.autoSave] }
    let autosaving = Debounce()
    var lspTask: Task<Void, Never>?
    /// Typed and not sent to the language server yet (changes go a moment after the last key).
    var lspUnsent: String?
    /// The connection (`AppModel.connections`) its language server was given this file on; nil when it has none. A new
    /// daemon knows nothing of it: the file is given again.
    var lspOpenedOn: Int?
    /// Its version as the daemon pushes it (`AppModel.fileVersions`), while the tab is open.
    private let version: Watched
    /// Its project's folder (the file's own folder outside every project); followed as the workspaces change.
    var root: String
    /// A remote project's file: no language server, formatter or notebook for it here; its preview shows a copy.
    let remote: Bool
    /// A remote image's or PDF's preview, once its copy is here.
    private var preview: NSView?
    /// A preview of a file here, built again when the file is written over.
    private var following: FollowedPreview?
    private var pendingLine: Int?
    /// Closed with Don't Save: deinit's autosave mustn't write it after all.
    private var discarded = false
    func discard() {
        discarded = true
        comparing?.cancel()
        isEdited = false
        backup.drop()
    }
    @ObservationIgnored lazy var backup = UnsavedBackup(app: app, uri: uri)
    /// The file was moved or deleted under the tab (often by an agent): the tab says so, ⌘S asks before writing it back.
    var gone = false
    /// The last save (each waits for the one before) and whether it wrote; `writing` while one is on its way to disk.
    var saving: Task<Bool, Never>?
    var writing = false
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
            let followed = FollowedPreview(url: url, app: app)
            following = followed
            view = followed.view
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
        track(owner: self) {   // the editor follows on its own; the page's preview is drawn here
            app.themes.editorRevision
        } changed: { [weak self] _ in
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
                await LSPManager.of(app).trust(root)
            }
        }
        track(owner: self) { [weak self] in
            self.map { LSPManager.of(app).restricts($0.root, $0.language) } ?? false
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
        if lspOpenedOn != nil { LSPManager.of(app).close(root: root, path: path) }
    }

    func focus() {
        guard let editor else {
            // A preview (an image, a PDF) takes the keys itself, so ⌘C copies from it.
            let shown = preview ?? following?.shown ?? view
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
    /// What was last read or written, and its version.
    var known: (stamp: FileStamp, text: String?)?
    var reading = false
    var readAgain = false

    /// What the tab says instead of the text (the daemon refuses it, here or on a host: `files.read`).
    static func reason(_ unopenable: Unopenable) -> String {
        switch unopenable {
        case .special: String(localized: "Kelp opens files, not devices or pipes.")
        case .tooBig(let size):
            String(
                localized:
                    "Too big to open here (\(DesignKit.bytes(size, file: true))). Open it with another app."
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
            copies: [(String(localized: "Web Link"), { @MainActor in copyWebLink(app, path) })])
    }

    /// What the tab shows instead of the file: the empty state, a warning when it couldn't be opened.

    private static func message(_ text: String, failed: Bool = true) -> NSView {
        let container = NSView(), empty = EmptyStateView()
        empty.place(in: container)
        if failed { empty.showError(text, text: nil) } else { empty.show(text, symbol: "icloud.and.arrow.down") }
        return container
    }
}
