import AppKit
import DesignKit
import WebKit
import Markdown
import EditorKit
import KelpKit
import Core

/// A Markdown file: editor, live preview, or both, with a formatting bar for specs and plans you write for agents. Also an
/// agent's page of HTML (a design, a dashboard), shown as it is, and its slides, cut into 16:9 slides.
@MainActor
final class MarkdownTab: NSViewController, WKScriptMessageHandler {
    let editor: CodeEditor
    let url: URL
    private let app: AppModel
    private let web = WKWebView()
    private let links: PreviewLinks
    private let mode = NSSegmentedControl(labels: [String(localized: "Edit"), String(localized: "Split"), String(localized: "Preview")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let split = NSSplitView()
    private var renderTask: Task<Void, Never>?
    /// Edited while the preview was hidden (Edit mode): rendered when it shows.
    private var dirty = false
    /// Documents to read (Kelp's help) open as the preview.
    var startInPreview = false {
        didSet {
            if isViewLoaded {
                mode.selectedSegment = startInPreview ? 2 : defaultSegment
                applyMode()
            }
        }
    }
    private var narrow = false
    /// Until then the source is following the preview, and doesn't lead it back.
    private var followingPreview = Date.distantPast
    /// Told whether the source can be edited on screen: the status bar's cursor means nothing in the preview.
    var onEditing: ((Bool) -> Void)?
    /// Writes the file: a review's picks are answers the agent reads from disk.
    var saveFile: (() async -> Bool)?
    /// A review an agent wrote: its page is answered, not read (`ReviewPage`).
    private var isReview: Bool { Review.isReview(url.path) }
    /// An agent's page of HTML: the preview is the file itself.
    private var isHTML: Bool { ["html", "htm"].contains(url.pathExtension.lowercased()) }
    private var isSlides: Bool { url.lastPathComponent == Artifacts.Kind.slides.file && ArtifactBar.isPage(url.path) }
    /// An older version of the page, shown in the preview instead of the file and not answered or edited (`ArtifactBar`).
    private(set) var shownVersion: String?

    private var artifactBar: ArtifactBar?
    /// A page an agent made: its title, for the tab.
    var onPageTitle: ((String?) -> Void)?

    /// What goes over the tab: a page an agent made has its bar (what it is, its versions, its chat) where the path would be.
    func header(else crumbs: NSView) -> NSView {
        guard ArtifactBar.isPage(url.path) else { return crumbs }
        let a = ArtifactBar(app: app, path: url.path, markdown: self)
        artifactBar = a
        return a.view
    }

    /// 0 edit, 1 split, 2 preview, as the bar's segments.
    var modeSegment: Int {
        get { mode.selectedSegment }
        set { selectMode(newValue) }
    }

    func showVersion(_ text: String?) {
        shownVersion = text
        if text != nil, modeSegment != 2 { modeSegment = 2 }
        mode.isEnabled = text == nil
        rerender()
    }

    /// The file becomes `text` and is saved: an older version restored.
    func restore(_ text: String) {
        editor.apply(text: text, selection: NSRange(location: 0, length: 0))
        Task { _ = await saveFile?() }
    }

    /// The page as the preview shows it, through the system's print panel (which saves a PDF too).
    func printPage() {
        guard let window = view.window else { return }
        if web.isHidden { selectMode(2) }
        let op = web.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    var currentMode: String {
        switch mode.selectedSegment {
        case 0: "edit"
        case 1: "split"
        default: "preview"
        }
    }

    private var defaultSegment: Int {
        switch app.settings.string("markdown.defaultMode") {
        case "edit": 0
        case "split": 1
        default: 2
        }
    }

    init(editor: CodeEditor, url: URL, app: AppModel) {
        self.app = app
        links = PreviewLinks(app: app)
        self.editor = editor; self.url = url
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The bar's and the selection bar's icon button.
    static func toolButton(_ sym: String, _ tip: String, _ sel: Selector, target: AnyObject) -> NSButton {
        IconButton(.symbol(sym), tip: tip, target: target, action: sel)
    }

    override func loadView() {
        func b(_ sym: String, _ tip: String, _ sel: Selector) -> NSButton { Self.toolButton(sym, tip, sel, target: self) }
        func gap() -> NSView {
            let line = NSBox(); line.boxType = .separator
            line.heightAnchor.constraint(equalToConstant: 14).isActive = true
            return line
        }
        mode.selectedSegment = startInPreview ? 2 : defaultSegment
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.controlSize = .small
        // Headings: a menu from one button (its first item is the button's face).
        let heading = PointerPopUpButton(frame: .zero, pullsDown: true)   // greys in under the pointer, as the bar's icons
        heading.addItems(withTitles: ["", String(localized: "Text"), String(localized: "Heading 1"), String(localized: "Heading 2"),
                                      String(localized: "Heading 3")])
        heading.item(at: 0)?.image = .symbol("textformat.size", String(localized: "Heading"))
        heading.toolTip = String(localized: "Heading")
        heading.target = self; heading.action = #selector(headingPicked(_:))
        formatting.setViews([heading, gap(), b("bold", String(localized: "Bold (⌘B)"), #selector(bold)),
                             b("italic", String(localized: "Italic (⌘I)"), #selector(italic)),
                             b("chevron.left.forwardslash.chevron.right", String(localized: "Code"), #selector(code)),
                             b("link", String(localized: "Link (⌘K)"), #selector(link)), gap(),
                             b("list.bullet", String(localized: "Bulleted list"), #selector(bullets)),
                             b("list.number", String(localized: "Numbered list"), #selector(numbered)),
                             b("checklist", String(localized: "Task list"), #selector(tasks)),
                             b("tablecells", String(localized: "Table"), #selector(table))], in: .leading)
        formatting.spacing = Metrics.iconGap
        let bar = Bar.content([formatting], [mode])
        split.isVertical = true; split.dividerStyle = .thin
        web.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        web.navigationDelegate = links
        web.configuration.userContentController.add(WeakHandler(self), name: "kelpSync")
        split.addArrangedSubview(editor.view); split.addArrangedSubview(web)
        editor.view.clipsToBounds = true
        // An agent's page has its own bar, whose ⋯ holds the modes (and ⇧⌘V cycles them): one bar over it, not two.
        view = artifactBar == nil ? stacked(bar, split) : stacked(split)
        view.addSubview(selectionBar)   // over the text, placed by frame
        editor.onSelection = { [weak self] in self?.placeSelectionBar() }
        if let clip = (editor.view as? NSScrollView)?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
        applyMode()
        rerender()
    }

    private let formatting = NSStackView()
    private lazy var selectionBar = MarkdownSelectionBar(target: self, items: [
        ("bold", String(localized: "Bold (⌘B)"), #selector(bold)), ("italic", String(localized: "Italic (⌘I)"), #selector(italic)),
        ("chevron.left.forwardslash.chevron.right", String(localized: "Code"), #selector(code)), ("link", String(localized: "Link (⌘K)"), #selector(link))
    ])

    /// Over the selection once it's made (not while the mouse is still dragging it); gone without one.
    private func placeSelectionBar() {
        guard NSEvent.pressedMouseButtons == 0, !isHTML, !editor.view.isHidden, let r = editor.selectionRect else { return selectionBar.isHidden = true }
        selectionBar.show(over: view.convert(r, from: editor.view), in: view)
    }

    @objc private func scrolled() {
        if !selectionBar.isHidden { placeSelectionBar() }
        guard currentMode == "split", !web.isHidden, Date() > followingPreview else { return }
        web.evaluateJavaScript("kelpToLine(\(editor.topLine))", completionHandler: nil)
    }

    /// `html` with a policy, first in its head, that runs only scripts carrying `nonce` (Kelp's own, added after it).
    nonisolated static func scriptless(_ html: String, nonce: String) -> String {
        let policy = #"<meta http-equiv="Content-Security-Policy" content="script-src 'nonce-\#(nonce)'; script-src-attr 'none'; object-src 'none'">"#
        let at = html.range(of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
            ?? html.range(of: #"<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive])
        guard let at else { return policy + html }
        return html[..<at.upperBound] + policy + html[at.upperBound...]
    }

    /// From the preview's page: scrolled to a line (the source follows), or double-clicked on one (the cursor goes there).
    /// Only from the page Kelp loaded: one the preview was taken away to (a meta refresh, a form) isn't heard.
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.frameInfo.isMainFrame, m.frameInfo.request.url?.isFileURL != false else { return }
        if artifactBar != nil, let body = m.body as? [String: Any], body["kind"] as? String == "ask" { return ask(about: body["text"] as? String ?? "") }
        if isReview, let body = m.body as? [String: Any], let kind = body["kind"] as? String, ["pick", "note", "send"].contains(kind) {
            guard shownVersion == nil else { return NSSound.beep() }   // an older version is read, not answered
            return answer(kind, point: body["point"] as? String ?? "", value: body[kind == "pick" ? "key" : "text"] as? String ?? "")
        }
        guard let body = m.body as? [String: Any], let line = (body["line"] as? NSNumber)?.intValue else { return }
        if body["kind"] as? String == "open" {
            if currentMode == "preview" { selectMode(1) }
            editor.goTo(line: line)
            editor.focus()
        } else if currentMode == "split" {
            followingPreview = Date().addingTimeInterval(0.2)
            editor.scroll(toLine: line)
        }
    }

    private func selectMode(_ segment: Int) {
        mode.selectedSegment = segment
        applyMode()
    }

    private var positioned = false
    override func viewDidLayout() {
        super.viewDidLayout()
        if !positioned, split.bounds.width > 700 { positioned = true; split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
        // Split in a narrow pane squeezes the preview to a word per line: show the source until there's room.
        let n = split.bounds.width > 0 && split.bounds.width < 760
        if n != narrow {
            narrow = n
            mode.setToolTip(n ? String(localized: "Split (needs a wider pane)") : nil, forSegment: 1)
            applyMode()
        }
    }

    func textChanged() { rerender(after: .milliseconds(250)) }
    /// The theme changed: the preview takes its page colours again.
    func themeChanged() { rerender() }

    /// The page is built off the main thread (a long document, or mermaid's 3.5 MB script inlined), and not at all
    /// while only the source shows.
    private func rerender(after delay: Duration = .zero) {
        renderTask?.cancel()
        guard !web.isHidden else { dirty = true; return }
        dirty = false
        renderTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let text = shownVersion ?? editor.text, base = url.deletingLastPathComponent()
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var page: (background: String, text: String)?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                let p = CodeEditor.page
                page = (p.background.hexString, p.text.hexString)
            }
            let review = isReview, slides = isSlides, raw = isHTML, sendTo = pageAuthor?.title
            // A page of HTML (a design, a dashboard) may be a cloned repository's: its own scripts don't run, Kelp's do.
            let nonce = UUID().uuidString
            let ask = artifactBar == nil ? "" : PageAsk.script(label: Self.jsString(String(localized: "Ask Agent")))
            let html = await Task.detached { [page] in
                if raw { return Self.scriptless(text, nonce: nonce) }
                if review {
                    let body = ReviewPage.body(Review(text), sendTo: sendTo)
                    return MarkdownHTML.page(body: body, baseURL: base, dark: dark, page: page) + ReviewPage.extras
                }
                return MarkdownHTML.page(body: MarkdownHTML.render(text, marking: true), baseURL: base, dark: dark, page: page)
                    + (slides ? MarkdownHTML.slides : "") + (MarkdownHTML.mermaid(for: text, dark: dark) ?? "") + MarkdownHTML.scrollSync
            }.value
            guard !Task.isCancelled else { return }
            // Keep the reader's place across re-renders (scrollY is always a number, so the async call can't trap on nil).
            let y = (try? await web.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            guard !Task.isCancelled else { return }
            // In Split, on the block being edited; the place it had otherwise.
            let place = currentMode == "split" && !review && !raw ? "kelpToLine(\(editor.cursor?.line ?? 1))" : "window.scrollTo(0, \(y))"
            let tail = (ask + "<script>\(place)</script>").replacingOccurrences(of: "<script>", with: raw ? "<script nonce=\"\(nonce)\">" : "<script>")
            web.loadHTMLString(html + tail, baseURL: base)
        }
    }

    @objc private func modeChanged() { applyMode() }

    // MARK: a review's answers

    /// The chat that made this page (a review's answers go back to it, and questions about it), while it's there.
    private var pageAuthor: Session? {
        Artifacts.record(in: url.deletingLastPathComponent())?.session.flatMap(app.session).flatMap { $0.status == .exited ? nil : $0 }
    }

    /// A pick or a note goes into the file (the agent reads its answers there); Send types the line saying them into
    /// the chat that wrote it, or, once that has ended, into the agent on screen for the user to send.
    private func answer(_ kind: String, point: String, value: String) {
        switch kind {
        case "pick": editor.apply(text: Review.pick(editor.text, point: point, option: value), selection: NSRange(location: 0, length: 0))
        case "note": editor.apply(text: Review.note(editor.text, point: point, note: value), selection: NSRange(location: 0, length: 0))
        default: break
        }
        Task {
            guard await saveFile?() != false else { return }
            guard kind == "send" else { return }
            let line = Review(editor.text).answer(file: Artifacts.projectPath(url.path))
            guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
            guard await app.call(SessionSend(id: author.id, text: line, enter: true)) != nil else { return }
            let sent = String(localized: "Sent to \(author.title)")
            web.evaluateJavaScript("kelpReviewSent(\(Self.jsString(sent)))", completionHandler: nil)
        }
    }

    /// Text selected on the page, quoted into the chat that made it (else the agent on screen), not sent: the user asks.
    private func ask(about quote: String) {
        let q = quote.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        guard !q.isEmpty else { return }
        let line = "About “\(q.count > 400 ? String(q.prefix(399)) + "…" : q)” in \(Artifacts.projectPath(url.path)):"
        guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
        Task { await app.call(SessionSend(id: author.id, text: line + " ", enter: false)) }
        app.workbench.focus(session: author.id)
    }

    /// A JavaScript string literal.
    private static func jsString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// ⇧⌘V: source → split → preview → source (split is skipped while the pane is too narrow for it).
    func cycleMode() {
        var m = (mode.selectedSegment + 1) % 3
        if m == 1, narrow { m = 2 }
        mode.selectedSegment = m; applyMode()
        if m != 2 { editor.focus() }
    }

    private func applyMode() {
        let m = mode.selectedSegment
        editor.view.isHidden = m == 2; web.isHidden = m == 0 || (m == 1 && narrow)
        formatting.isHidden = m == 2   // nothing to format in the preview
        onEditing?(m != 2)
        placeSelectionBar()
        split.adjustSubviews()
        if m == 1, !narrow { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
        if dirty, !web.isHidden { rerender() }
    }

    private func edit(_ f: (String, NSRange) -> (text: String, selection: NSRange)) {
        let r = f(editor.text, editor.selectedRange)
        editor.apply(text: r.text, selection: r.selection)
        editor.focus()
    }
    @objc func bold() { edit(MarkdownFormat.toggleBold) }
    @objc func italic() { edit(MarkdownFormat.toggleItalic) }
    @objc func code() { edit(MarkdownFormat.toggleCode) }
    @objc func bullets() { edit(MarkdownFormat.toggleBullet) }
    @objc func numbered() { edit(MarkdownFormat.toggleNumbered) }
    @objc func tasks() { edit(MarkdownFormat.toggleTask) }
    @objc private func table() { edit { MarkdownFormat.insertTable($0, $1, columns: 3, rows: 2) } }
    @objc private func headingPicked(_ p: NSPopUpButton) {
        let l = p.indexOfSelectedItem - 1   // past the button's face: Text, Heading 1…3
        guard l >= 0 else { return }
        edit { MarkdownFormat.heading($0, $1, level: l) }
    }
    @objc func link() {
        Task {
            guard let u = await prompt(String(localized: "Insert link"), "URL", initial: "https://") else { return }
            edit { MarkdownFormat.makeLink($0, $1, url: u) }
        }
    }
}
