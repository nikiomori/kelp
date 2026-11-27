import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import Markdown
import WebKit

/// A rendered Jupyter notebook. Run All re-executes it in place; Open Kernel starts Jupyter Lab in this worktree
/// and shows it in the built-in browser, so the kernel stays alive next to your agents.
@MainActor
final class NotebookTab: NSViewController {
    let app: AppModel
    let url: URL, path: String, worktreeId: String?
    private let web = WKWebView()
    private let links: PreviewLinks
    /// What the tab is doing or what the notebook holds, a sentence that wraps in a narrow pane.
    private let status = NSTextField.sentence("", font: .ui(TextSize.caption))
    /// What the tab says when the notebook couldn't be read or isn't one.
    private let empty = EmptyStateView()
    /// Says the notebook is being read, once that has taken a second.
    private let loading = LoadingView()
    /// The agents' working ring while Run All runs: work that goes on by itself, maybe for hours.
    private let ring = StatusMark(size: 12)
    private lazy var run = TextButton(String(localized: "Run All"), target: self, action: #selector(runAll))

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
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        // Worded buttons carry no symbol (the design's rule for buttons with words).
        let bar = Bar.content(
            [
                run,
                TextButton(String(localized: "Open Kernel"), target: self, action: #selector(openKernel)),
                TextButton(String(localized: "Ask Agent"), target: self, action: #selector(askAgent))
            ], [status, ring], stretching: status)
        web.navigationDelegate = links
        view = stacked(bar, web)
        empty.place(in: view, under: bar)
        loading.place(in: view, under: bar)
        // Rendered again in the editor's colours when the theme or the appearance changes them.
        track(owner: self) { [app] in
            app.themes.editorRevision
        } changed: { [weak self] _ in
            self?.reload()
        }
    }

    /// Reads the notebook through the daemon (off the main thread, and refused past the size limit like any file
    /// tab's file), then renders it. A read that failed says why, with Try Again; a file that isn't a notebook says so.
    func reload() {
        loading.wait(String(localized: "Reading the notebook…"))
        Task { [self] in
            let read = await app.tryCall(FilesRead(path: path))
            await loading.settled()
            loading.show(nil)
            let data = read.value.map { Data($0.text.utf8) }
            guard let data, let body = NotebookHTML.render(data) else {
                web.isHidden = true
                if let error = read.error {
                    let again = ClosureButton(title: String(localized: "Try Again")) { [weak self] in self?.reload() }
                    empty.showError(String(localized: "Couldn’t Read This Notebook"), text: error, buttons: [again])
                } else {
                    empty.showError(
                        String(localized: "Can’t Show This Notebook"),
                        text: String(localized: "It isn’t valid nbformat 4 JSON."))
                }
                return
            }
            web.isHidden = false
            empty.show(nil)
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var page: (background: String, text: String)?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                page = (CodeEditor.page.background.hexString, CodeEditor.page.text.hexString)
            }
            links.load(
                MarkdownHTML.page(body: body, baseURL: url.deletingLastPathComponent(), dark: dark, page: page),
                baseURL: url.deletingLastPathComponent(), scripts: [MarkdownHTML.math(for: body)].compactMap { $0 },
                world: MarkdownTab.world, in: web)
            if let summary = NotebookHTML.summary(data) {
                status.say(String(localized: "\(summary.cells) cells · \(summary.language)"))
            }
        }
    }

    private static func jupyter() -> String? {
        ["/opt/homebrew/bin/jupyter", "/usr/local/bin/jupyter", NSHomeDirectory() + "/.local/bin/jupyter"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func noJupyter() {
        Banner.show(String(localized: "Jupyter not found — pip install jupyter"), style: .error)
    }

    @objc private func runAll() {
        guard let jupyter = Self.jupyter() else { return Self.noJupyter() }
        status.say(String(localized: "Running all cells…"))
        ring.status = .working
        run.isEnabled = false   // a second run would execute the same file over the first
        let file = url
        Task {
            // A notebook may compute for hours, so the timeout only catches one that never ends.
            let result = await Shell.exec(
                app, [jupyter, "nbconvert", "--to", "notebook", "--execute", "--inplace", file.path],
                cwd: file.deletingLastPathComponent().path, timeout: 12 * 3600)
            let msg = result.stderr.split(separator: "\n").last.map(String.init) ?? ""
            ring.status = nil
            run.isEnabled = true
            // What was asked failed: a banner with the error's mark, not a grey line in the bar.
            status.say(result.code == 0 ? String(localized: "Ran all cells") : "")
            if result.code != 0 { Banner.show(String(localized: "Couldn’t run the notebook: \(msg)"), style: .error) }
            reload()
        }
    }

    @objc private func openKernel() {
        guard let wid = worktreeId else { return }
        guard Self.jupyter() != nil else { return Self.noJupyter() }
        Task {
            guard
                let session = await app.call(
                    app.workbench.sized(
                        SessionCreate(
                            worktreeId: wid, command: "jupyter lab --no-browser " + ShellQuote.word(path),
                            title: "Jupyter", openURLs: true)))
            else { return }
            app.upsert(session)   // the session's own event may have arrived first
            // Jupyter's URL arrives as a dev-server URL and opens in a browser tab
            status.say(String(localized: "Starting Jupyter Lab… it opens in the Browser tab"))
        }
    }

    @objc private func askAgent() {
        FileActions(app).sendToAgent(text: "Look at the notebook \(path) (cells and outputs).")
    }
}
