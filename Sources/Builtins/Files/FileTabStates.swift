import AppKit
import DesignKit
import EditorKit
import KelpKit

/// The views a file tab shows besides its text: the question whether to trust the project's code, the merge conflicts
/// bar, and the way out when the file is gone.
extension FileTab {
    /// Returns the breadcrumbs with the trust question (`TrustBar`) under them. The question stays hidden while the
    /// project doesn't need to be asked.
    func withTrustBar(_ crumbs: NSView) -> NSView {
        guard !remote else { return crumbs }   // a remote file gets no language server here
        let app = self.app
        let trust = TrustBar.make(
            project: (root as NSString).lastPathComponent,
            notNow: { [weak self] in self.map { LSPManager.of(app).notNow($0.root) } },
            trust: { [weak self] in self?.trustProject() })
        trust.isHidden = true
        track(owner: self) { [weak self] in
            self.map { LSPManager.of(app).asks($0.root, $0.language) } ?? false
        } changed: { [weak self, weak trust] asks in
            guard let trust, trust.isHidden == asks else { return }
            // It comes and goes as a dissolve over the tab, the code moving with it, not in one frame.
            self?.view.crossfade(asks ? Motion.base : Motion.fast)
            trust.isHidden = !asks
        }
        return bars(crumbs, trust)
    }

    /// Whether the project isn't trusted to run this file's language server or formatter (Trust This Project acts
    /// only then).
    var restricted: Bool { !remote && LSPManager.of(app).restricts(root, language) }

    /// Trusts the file's project to run its language servers and formatters, as the trust bar's Trust does.
    func trustProject() {
        Task { [app, root] in await LSPManager.of(app).trust(root) }
    }

    /// Returns the merge conflicts bar shown over `editor`. Its label follows the caret.
    func withConflictBar(_ editor: CodeEditor) -> NSView {
        let conflictBar = ConflictBar(editor: editor)
        conflicts = conflictBar
        let before = editor.onSelection
        editor.onSelection = { [weak conflictBar] in
            before?()
            conflictBar?.caretMoved()
        }
        return conflictBar.bar
    }

    /// Returns the view for a file that was moved or deleted. It offers a way out of the tab, and a way to the Files
    /// panel, where the file was.
    func missing() -> NSView {
        let app = self.app, uri = self.uri
        let close = ClosureButton(title: String(localized: "Close Tab")) { app.workbench.closeTab(uri: uri) }
        let files = ClosureButton(title: String(localized: "Show in Files")) { app.workbench.showPanel("files") }
        let container = NSView(), empty = EmptyStateView()
        empty.place(in: container)
        empty.showError(
            String(localized: "File Not Found"), text: String(localized: "It was moved or deleted."),
            buttons: [close, files])
        return container
    }
}
