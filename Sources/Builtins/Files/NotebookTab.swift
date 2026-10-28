import AppKit
import WebKit
import Markdown
import Core
import DesignKit
import KelpKit

/// A rendered Jupyter notebook. Run All re-executes it in place; Open Kernel starts Jupyter Lab in this worktree
/// and shows it in the built-in browser, so the kernel stays alive next to your agents.
@MainActor
final class NotebookTab: NSViewController {
    let app: AppModel
    let url: URL, path: String, worktreeId: String?
    private let web = WKWebView()
    private let links: PreviewLinks
    private let status = NSTextField(labelWithString: "")

    init(app: AppModel, url: URL, path: String, worktreeId: String?) {
        links = PreviewLinks(app: app)
        self.app = app
        self.url = url
        self.path = path
        self.worktreeId = worktreeId
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        func b(_ t: String, _ sym: String, _ sel: Selector) -> NSButton {
            let x = NSButton(title: t, target: self, action: sel)
            x.image = .symbol(sym)
            x.imagePosition = .imageLeading
            x.bezelStyle = .push
            x.controlSize = .small
            return x
        }
        status.textColor = .secondaryLabelColor; status.font = .ui(11)
        let bar = Bar.content([b(String(localized: "Run All"), "play.fill", #selector(runAll)),
                               b(String(localized: "Open Kernel"), "server.rack", #selector(openKernel)),
                               b(String(localized: "Ask Agent"), "text.bubble", #selector(askAgent))], [status])
        web.navigationDelegate = links
        view = stacked(bar, web)
        reload()
    }

    /// Read by the daemon (off the main thread, refused like any file tab's past the size limit), then rendered.
    func reload() {
        Task {
            let d = await app.tryCall(FilesRead(path: path)).value.map { Data($0.text.utf8) }
            guard let d, let body = NotebookHTML.render(d) else {
                let why = String(localized: "This notebook can't be read (is it valid nbformat 4 JSON?).")
                web.loadHTMLString(EmptyStateView.html(String(localized: "Can't show this notebook"), text: why), baseURL: nil)
                return
            }
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            web.loadHTMLString(MarkdownHTML.page(body: body, baseURL: url.deletingLastPathComponent(), dark: dark), baseURL: url.deletingLastPathComponent())
            if let s = NotebookHTML.summary(d) { status.stringValue = String(localized: "\(s.cells) cells · \(s.language)") }
        }
    }

    private static func jupyter() -> String? {
        ["/opt/homebrew/bin/jupyter", "/usr/local/bin/jupyter", NSHomeDirectory() + "/.local/bin/jupyter"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @objc private func runAll() {
        guard let j = Self.jupyter() else { status.stringValue = String(localized: "Jupyter not found — pip install jupyter"); return }
        status.stringValue = String(localized: "Running…")
        let file = url
        Task {
            // A notebook may compute for hours: the timeout is only for one that never ends.
            let r = await Shell.exec(app, [j, "nbconvert", "--to", "notebook", "--execute", "--inplace", file.path],
                                     cwd: file.deletingLastPathComponent().path, timeout: 12 * 3600)
            let msg = r.stderr.split(separator: "\n").last.map(String.init) ?? ""
            status.stringValue = r.code == 0 ? String(localized: "Ran all cells") : String(localized: "Failed: \(msg)")
            reload()
        }
    }

    @objc private func openKernel() {
        guard let wid = worktreeId else { return }
        guard Self.jupyter() != nil else { status.stringValue = String(localized: "Jupyter not found — pip install jupyter"); return }
        Task {
            guard let s = await app.call(SessionCreate(worktreeId: wid, command: "jupyter lab --no-browser " + IDE.shellWord(path),
                                                                   title: "Jupyter", openURLs: true)) else { return }
            app.sessions.append(s)
            // Jupyter's URL arrives as a dev-server URL and opens in a browser tab
            status.stringValue = String(localized: "Starting Jupyter Lab… it opens in the Browser tab")
        }
    }

    @objc private func askAgent() {
        guard let sid = app.workbench.focusedSession else { NSSound.beep(); return }
        Task { await app.call(SessionSend(id: sid, text: "Look at the notebook \(path) (cells and outputs). ", enter: false)) }
    }
}
