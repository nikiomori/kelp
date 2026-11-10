import AppKit
import DesignKit
import KelpKit

/// What a file tab shows besides its text: the trust question over code, and the way out when the file is gone.
extension FileTab {
    /// The breadcrumbs with the trust question under them (`TrustBar`), hidden while it doesn't ask.
    func withTrustBar(_ crumbs: NSView) -> NSView {
        guard !remote else { return crumbs }   // a host's file: no language server here
        let app = self.app
        let trust = TrustBar.make(
            project: (root as NSString).lastPathComponent,
            notNow: { [weak self] in self.map { LSPManager.of(app).notNow($0.root) } },
            trust: { [weak self] in
                guard let root = self?.root else { return }
                Task { await LSPManager.of(app).trust(root) }
            })
        trust.isHidden = true
        track(owner: self) { [weak self] in
            self.map { LSPManager.of(app).asks($0.root, $0.language) } ?? false
        } changed: { [weak trust] in
            trust?.isHidden = !$0
        }
        let column = NSStackView(views: [crumbs, trust])
        column.orientation = .vertical
        column.spacing = 0
        column.detachesHiddenViews = true
        for part in [crumbs, trust] { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    /// Moved or deleted: a way out of the tab, and to where the file was.
    func missing() -> NSView {
        let app = self.app, uri = self.uri
        let close = ClosureButton(title: String(localized: "Close Tab")) { app.workbench.closeTab(uri: uri) }
        let files = ClosureButton(title: String(localized: "Show in Files")) { app.workbench.showPanel("files") }
        let container = NSView(), empty = EmptyStateView()
        empty.place(in: container)
        empty.showError(
            String(localized: "File not found — it was moved or deleted."), text: nil, buttons: [close, files])
        return container
    }
}
