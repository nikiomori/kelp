import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// A file shown as a tab: a code editor with a language server, Markdown with a preview, a notebook, or a Quick Look
/// preview. It behaves like a Mac document: edits show as a dot on the tab and on the window's close button, ⌘S saves,
/// and closing asks first (Settings › Editor › Save automatically turns autosave on). Agents edit files on disk too, so
/// a buffer with no edits follows the disk and conflicting edits ask. The daemon reads and writes the file (here or on
/// a remote project's host) and says when its version changes (`WatchTopic.file`). The tab never touches the file.
@MainActor @Observable
final class FileTab: SavableTab {
    let path: String, url: URL
    let app: AppModel
    let view: NSView
    private(set) var editor: CodeEditor?
    /// The bar shown over the text while the file holds merge conflicts.
    var conflicts: ConflictBar?
    private(set) var markdown: MarkdownTab?
    /// A page an agent made is named by its title, not "doc.md", and its icon shows what kind of page it is.
    private var pageTitle: String?
    private var pageKind: Artifacts.Kind?
    private var notebook: NotebookTab?
    var changeBars: ChangeBars?
    /// The file's indentation rules and what Save tidies up.
    private(set) var rules: FileRules?
    weak var statusBar: EditorStatusBar?
    /// The text the file was last read or written as. Setting it cancels a running compare, because a compare against
    /// the old text is moot.
    var lastSaved = "" { didSet { comparing?.cancel() } }
    var isEdited = false
    /// The number of edits so far, so a save can tell whether the buffer still holds the text it wrote.
    var edits = 0
    var comparing: Task<Void, Never>?
    var autosave: Bool { app.settings[SettingKeys.autoSave] }
    let autosaving = Debounce()
    var lspTask: Task<Void, Never>?
    /// Text typed but not yet sent to the language server (changes are sent a moment after the last key).
    var lspUnsent: String?
    /// The daemon connection (`AppModel.connections`) on which the language server was given this file; nil when no
    /// server has it. A new daemon knows nothing of the file, so the file is given to the server again.
    var lspOpenedOn: Int?
    /// The file's version as the daemon pushes it while the tab is open (a `.file` watch, `Watched`).
    private let version: Watched
    /// The folder of the file's project, or the file's own folder when no project holds it. It is updated as the
    /// workspaces change.
    var root: String
    /// True for a file in a remote project. Such a file gets no language server, formatter or notebook here, and its
    /// preview shows a local copy.
    let remote: Bool
    /// The preview of a remote image or PDF, once its copy is here.
    private var preview: NSView?
    /// A preview of a file here, built again when the file is written over.
    private var following: FollowedPreview?
    private var pendingLine: Int?
    /// Set when the tab was closed with Don't Save, so the autosave in deinit must not write the file after all.
    private var discarded = false
    func discard() {
        discarded = true
        comparing?.cancel()
        isEdited = false
        backup.drop()
    }
    @ObservationIgnored lazy var backup = UnsavedBackup(app: app, uri: uri)
    /// True when the file was moved or deleted under the tab (often by an agent). The tab says so, and ⌘S asks before
    /// writing the file back.
    var gone = false
    /// The last save and whether it wrote (each save waits for the one before it). `writing` is true while a save is on
    /// its way to disk.
    var saving: Task<Bool, Never>?
    var writing = false
    /// Set when the tab was focused while its text was still loading, so the editor takes focus (and shows the pending
    /// line) once the text arrives.
    private var focusWhenLoaded = false
    /// Whether the tab is on screen, and the work that waits until it shows (such as the disk's newest version).
    @ObservationIgnored lazy var whenShown = WhenShown(view)
    /// The first read (tests wait for it).
    private(set) var loading: Task<Void, Never>?

    var uri: String { TabURI.file(path) }
    var fileURL: URL? { url }
    var title: String { pageTitle ?? url.lastPathComponent }
    var icon: NSImage? {
        gone
            ? .symbol("exclamationmark.triangle", String(localized: "Moved or deleted"))
            : (pageKind ?? ArtifactBar.kind(ofFile: path)).map(ArtifactBar.icon)
                ?? app.fileIcons.image(url.lastPathComponent)
    }
    var toolTip: String? { gone ? goneNote(path) : path }

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
        // The daemon reads the file off the main thread. It reads only a regular file (a pipe or /dev/zero would block
        // or never end), only up to `openLimit` (a 300 MB log would hang the window), and as UTF-8. A remote project's
        // file is read on its host. A remote image or PDF is copied here instead, because Quick Look and PDFKit need a
        // local file.
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
                    let previewView = await Preview.view(for: copy, app: app)
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
            // The file was moved or deleted (often by an agent) after the tab opened. Say so, rather than show an empty
            // buffer that ⌘S would write.
            case .failure(let error as RPCError)
            where error.code == RPCError.invalidParams("").code && Unopenable(error) == nil:
                box.pin(missing())
            case .failure(let error):
                box.pin(Self.message(Unopenable(error).map(Self.reason) ?? AppModel.message(error)))
            }
        }
    }

    /// Called once the file's text arrives. Shows the editor (Markdown with its preview, or code with a status bar),
    /// starts the language server, and follows the file's version from then on.
    private func loaded(_ file: FilesRead.Result, in box: NSView) {
        let app = self.app
        let found = ChangeBars.project(of: path, in: app.worktrees)
        root = found?.worktree.path ?? root   // the workspaces may have loaded since init
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
        wire(bar, to: codeEditor)
        bar.show(cursor: codeEditor.cursor)
        statusBar = bar
        let crumbs = Breadcrumbs(app: app, path: inside, root: root, editor: codeEditor)
        let conflictBar = withConflictBar(codeEditor)
        let language = codeEditor.languageId
        // Word wrap is read per file, because the file's language may override the setting for all files. A change to
        // either setting shows at once.
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
            md.onPageTitle = { [weak self] title, kind in
                self?.pageTitle = title
                self?.pageKind = kind
            }
            markdown = md
            // An agent's page has no status bar: its own bar says what it is, and its lines mean nothing in the page.
            if ArtifactBar.isPage(path) {
                box.pin(stacked(md.header(else: crumbs), conflictBar, md.view))
            } else {
                box.pin(stacked(md.header(else: crumbs), conflictBar, md.view, bar))
            }
            md.attach(bar)
        } else {
            box.pin(stacked(withTrustBar(crumbs), conflictBar, codeEditor.view, bar))
        }
        let before = codeEditor.onSelection   // kept, because Markdown's selection bar follows the selection too
        codeEditor.onSelection = { [weak bar, weak codeEditor] in
            before?()
            bar?.show(cursor: codeEditor?.cursor)
            bar?.show(problem: codeEditor?.problemAtCursor?.message)
        }
        codeEditor.onChange = { [weak self] t in self?.edited(t) }
        if let kept = backup.text {   // the unsaved text a crash left behind
            if kept == text {
                backup.drop()
            } else {
                codeEditor.setText(kept)
                edited(kept)
            }
        }
        codeEditor.contextMenu = { [weak self] m in self?.contextMenu(m) }
        track(owner: self) {   // the editor follows the theme itself; the Markdown preview is redrawn here
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
        // Follow the file's version on disk, here or on its host (where the daemon checks the file's digest at times).
        let filePath = path
        version.key = filePath
        track(owner: self) { [app] in
            app.latest(FileEvent.self, filePath)
        } changed: { [weak self] _ in
            self?.diskChanged()
        }
        guard !remote else { return }   // a remote file gets no language server here
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
        nameServers(in: bar)
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
        // The tab was dropped without close() (its workspace went away and its save failed). Autosave writes what is
        // safe to write and never writes over a conflict, because the daemon writes only over the version last read or
        // written here. The write is sent now, because nothing may hold the tab once it is gone (a save on its way
        // would hold it, so none is running). Either way the backup keeps the text (see the deinit in `UnsavedBackup`)
        // until a workspace that holds the file takes it back.
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
        guard let editor else {   // the text is still loading, so go to the line once it arrives
            pendingLine = line
            focusWhenLoaded = true
            return
        }
        editor.goTo(line: line)
        editor.focus()
    }
    /// The version and text last read or written.
    var known: (stamp: FileStamp, text: String?)?
    var reading = false
    var readAgain = false

    /// Returns what the tab says instead of the text when the daemon refuses to read the file (`files.read`), here or
    /// on a host.
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

    /// Adds the file's items to the context menu on its tab.

    static func menu(
        _ app: AppModel, _ menu: NSMenu, uri: String, workspace: String,
        openBeside: @escaping @MainActor (String) -> Void
    ) {
        let path = TabURI.filePath(uri).path
        menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path) }
        // A page on a remote host isn't on this Mac, so the browser can't load it.
        if ["html", "htm"].contains((path as NSString).pathExtension.lowercased()), RemoteHost.containing(path) == nil {
            menu.add(String(localized: "Open Preview to the Side")) { openBeside("preview:" + path) }
        }
        menu.addItem(.separator())
        WorkspaceActions.addLocate(
            to: menu, path: path,
            copies: [(String(localized: "Web Link"), { @MainActor in copyWebLink(app, path) })])
    }

    /// Returns the view the tab shows instead of the file: an empty state while the file is fetched, or a warning when
    /// the file couldn't be opened.

    private static func message(_ text: String, failed: Bool = true) -> NSView {
        let container = NSView(), empty = EmptyStateView()
        empty.place(in: container)
        if failed { empty.showError(text, text: nil) } else { empty.show(text, symbol: "icloud.and.arrow.down") }
        return container
    }

    /// The status bar's clicks run the editor's commands, and its wrap button names that command's key as it stands.
    private func wire(_ bar: EditorStatusBar, to codeEditor: CodeEditor) {
        bar.contextMenu = { [app, weak codeEditor] in EditorStatusBar.menu(app, language: codeEditor?.languageId) }
        bar.onWrap = { [app] in app.extensions.run("editor.toggleWordWrap") }
        bar.wrapTip = app.extensions.hint(String(localized: "Long lines wrap"), "editor.toggleWordWrap")
        bar.onProblems = { [app] in app.extensions.run("files.showProblems") }
    }
}
