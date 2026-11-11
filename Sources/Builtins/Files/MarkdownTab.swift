import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import Markdown
import WebKit

/// A Markdown file: editor, live preview, or both, with a formatting bar for specs and plans you write for agents. Also an
/// agent's page of HTML (a design, a dashboard), shown as it is, and its slides, cut into 16:9 slides.
@MainActor
final class MarkdownTab: NSViewController, WKScriptMessageHandler {
    let editor: CodeEditor
    let url: URL
    let app: AppModel
    private let web = WKWebView()
    private let links: PreviewLinks
    /// Where Kelp's scripts for the preview run (the page's own don't: `PreviewLinks`), and the only world `kelpSync` hears.
    static let world = WKContentWorld.world(name: "kelp")
    private let mode = NSSegmentedControl(
        labels: [String(localized: "Edit"), String(localized: "Split"), String(localized: "Preview")],
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
    var narrowPane: Bool { narrow }
    /// Until then the source is following the preview, and doesn't lead it back.
    private var followingPreview = Date.distantPast
    /// Told whether the source can be edited on screen: the status bar's cursor means nothing in the preview.
    var onEditing: ((Bool) -> Void)?
    /// Writes the file: a review's picks are answers the agent reads from disk.
    var saveFile: (() async -> Bool)?
    /// What the preview shows, from the file's path.
    enum Page {
        case markdown
        /// An agent's slides: the Markdown cut into 16:9 slides.
        case slides
        /// A review an agent wrote: its page is answered, not read (`ReviewPage`).
        case review
        /// An agent's page of HTML: the preview is the file itself.
        case html
        /// A design's canvas.json: the preview is its boards, drawn by Kelp (`CanvasPage`).
        case canvas

        @MainActor init(_ url: URL) {
            if url.lastPathComponent == Artifacts.Kind.design.file && ArtifactBar.isPage(url.path) {
                self = .canvas
            } else if ["html", "htm"].contains(url.pathExtension.lowercased()) {
                self = .html
            } else if Review.isReview(url.path) {
                self = .review
            } else if url.lastPathComponent == Artifacts.Kind.slides.file && ArtifactBar.isPage(url.path) {
                self = .slides
            } else {
                self = .markdown
            }
        }
    }
    let page: Page
    /// A canvas: the `kelp artifact check` waiting for its next drawing, and what the last one found.
    var pendingCheck: String?
    var checkIssues: [String]?
    /// A canvas: whether a click on a board puts a mark on it (Mark in the bar), whether it's being presented, and who
    /// hears that the presenting ended (Esc on the page).
    var marking = false, presentingBoards = false
    /// A canvas: whether a click chooses an element to change by hand (Edit in the bar), and the one chosen (its board
    /// and data-id), chosen again once the canvas is drawn again.
    var editing = false
    var chosen: (board: String, id: String)?
    /// A canvas: its size set by hand (nil: fitted), and the agent writing it now (its board gets the ring).
    var canvasZoom: Double?
    var canvasWriter: String? {
        didSet { if canvasWriter != oldValue, page == .canvas { rerender() } }
    }
    var onPresentEnded: (() -> Void)?
    /// A canvas that is a dashboard: drawn as a page of data (`CanvasPage.View.dashboard`).
    var isDashboard = false {
        didSet { if isDashboard != oldValue { rerender() } }
    }
    /// A doc: the page as its agent's last turn found it, to mark what the turn changed; and how many blocks it did.
    var baseline: String? {
        didSet { if baseline != oldValue { rerender() } }
    }
    var onChanges: ((Int) -> Void)?
    /// Told when the page turns Mark on itself (its Mark button under a selection).
    var onPageMode: ((CanvasMode) -> Void)?
    /// An older version of the page, shown in the preview instead of the file and not answered or edited (`ArtifactBar`).
    private(set) var shownVersion: String?

    private var artifactBar: ArtifactBar?
    /// A page an agent made: its title and kind, for the tab.
    var onPageTitle: ((String?, Artifacts.Kind?) -> Void)?
    /// A canvas: what its check found each time it's drawn (the bar shows it).
    var onCheck: (([String]) -> Void)?

    /// What goes over the tab: a page an agent made has its bar (what it is, its versions, its chat) where the path would be.
    func header(else crumbs: NSView) -> NSView {
        guard ArtifactBar.isPage(url.path) else { return crumbs }
        let bar = ArtifactBar(app: app, path: url.path, markdown: self)
        artifactBar = bar
        return bar.view
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
        if page == .canvas, let snapshot = CanvasSnapshot.read(text) { return restoreCanvas(snapshot) }
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
        switch app.settings[SettingKeys.markdownMode] {
        case "edit": 0
        case "split": 1
        default: 2
        }
    }

    init(editor: CodeEditor, url: URL, app: AppModel) {
        self.app = app
        links = PreviewLinks(app: app)
        self.editor = editor
        self.url = url
        page = Page(url)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The bar's and the selection bar's icon button.
    static func toolButton(_ sym: String, _ tip: String, _ sel: Selector, target: AnyObject) -> NSButton {
        IconButton(.symbol(sym), tip: tip, target: target, action: sel)
    }

    override func loadView() {
        func tool(_ sym: String, _ tip: String, _ sel: Selector) -> NSButton {
            Self.toolButton(sym, tip, sel, target: self)
        }
        func gap() -> NSView {
            let line = NSBox()
            line.boxType = .separator
            line.heightAnchor.constraint(equalToConstant: 14).isActive = true
            return line
        }
        mode.selectedSegment = startInPreview ? 2 : defaultSegment
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.controlSize = .small
        // Headings: a menu from one button (its first item is the button's face).
        let heading = PointerPopUpButton(frame: .zero, pullsDown: true)   // greys in under the pointer, as the bar's icons
        heading.addItems(withTitles: [
            "", String(localized: "Text"), String(localized: "Heading 1"), String(localized: "Heading 2"),
            String(localized: "Heading 3")
        ])
        heading.item(at: 0)?.image = .symbol("textformat.size", String(localized: "Heading"))
        heading.toolTip = String(localized: "Heading")
        heading.target = self
        heading.action = #selector(headingPicked(_:))
        formatting.setViews(
            [
                heading, gap(), tool("bold", String(localized: "Bold (⌘B)"), #selector(bold)),
                tool("italic", String(localized: "Italic (⌘I)"), #selector(italic)),
                tool("chevron.left.forwardslash.chevron.right", String(localized: "Code"), #selector(code)),
                tool("link", String(localized: "Link (⌘K)"), #selector(link)), gap(),
                tool("list.bullet", String(localized: "Bulleted list"), #selector(bullets)),
                tool("list.number", String(localized: "Numbered list"), #selector(numbered)),
                tool("checklist", String(localized: "Task list"), #selector(tasks)),
                tool("tablecells", String(localized: "Table"), #selector(table))
            ], in: .leading)
        formatting.spacing = Metrics.iconGap
        let bar = Bar.content([formatting])
        formattingBar = bar
        split.isVertical = true
        split.dividerStyle = .thin
        web.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        web.navigationDelegate = links
        web.allowsMagnification = page == .canvas   // pinch to look closer at a board
        web.configuration.userContentController.add(WeakHandler(self), contentWorld: Self.world, name: "kelpSync")
        split.addArrangedSubview(editor.view)
        split.addArrangedSubview(web)
        editor.view.clipsToBounds = true
        // An agent's page has its own bar, whose ⋯ holds the modes (and ⇧⌘V cycles them): one bar over it, not two.
        // Elsewhere the formatting bar goes in the preview (nothing to format there), and the modes sit in the status bar.
        if artifactBar == nil {
            let column = NSStackView(views: [bar, split])
            column.orientation = .vertical
            column.spacing = 0
            column.distribution = .fill
            column.detachesHiddenViews = true
            split.setContentHuggingPriority(.init(1), for: .vertical)
            for subview in [bar, split] { subview.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
            view = column
        } else {
            view = stacked(split)
        }
        view.addSubview(selectionBar)   // over the text, placed by frame
        editor.onSelection = { [weak self] in self?.placeSelectionBar() }
        if let clip = (editor.view as? NSScrollView)?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
        applyMode()
        rerender()
        if page == .canvas { followCanvas() }
    }

    private let formatting = NSStackView()
    private var formattingBar: Bar?
    /// The file's status bar: told whether the source is on screen, and given Edit, Split, Preview (an agent's page has
    /// them in its own bar's ⋯). After `header`, which says whether it's such a page.
    func attach(_ bar: EditorStatusBar) {
        onEditing = { [weak bar] in bar?.editing = $0 }
        bar.editing = mode.selectedSegment != 2
        if artifactBar == nil { bar.show(modes: mode) }
    }
    private lazy var selectionBar = MarkdownSelectionBar(
        target: self,
        items: [
            ("bold", String(localized: "Bold (⌘B)"), #selector(bold)),
            ("italic", String(localized: "Italic (⌘I)"), #selector(italic)),
            ("chevron.left.forwardslash.chevron.right", String(localized: "Code"), #selector(code)),
            ("link", String(localized: "Link (⌘K)"), #selector(link))
        ])

    /// Over the selection once it's made (not while the mouse is still dragging it); gone without one.
    private func placeSelectionBar() {
        guard NSEvent.pressedMouseButtons == 0, page != .html, page != .canvas, !editor.view.isHidden,
            let selection = editor.selectionRect
        else {
            return selectionBar.isHidden = true
        }
        selectionBar.show(over: view.convert(selection, from: editor.view), in: view)
    }

    /// The preview shown, and keys going to it (a canvas being presented steps with ← →).
    func focusPreview() {
        if modeSegment != 2 { modeSegment = 2 }
        view.window?.makeFirstResponder(web)
    }

    /// Script for the page whose answer nobody waits for (the async evaluateJavaScript traps on an undefined result).
    func runJS(_ js: String) { web.evaluateJavaScript(js, in: nil, in: Self.world, completionHandler: nil) }

    @objc private func scrolled() {
        if !selectionBar.isHidden { placeSelectionBar() }
        guard currentMode == "split", !web.isHidden, Date() > followingPreview else { return }
        runJS("kelpToLine(\(editor.topLine))")
    }

    /// From Kelp's scripts beside the preview's page (`world`; the page's own don't run): scrolled to a line
    /// (the source follows), or double-clicked on one (the cursor goes there).
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL != false else { return }
        let agents = page == .canvas || (artifactBar != nil && (page == .markdown || page == .slides))
        if agents, let body = message.body as? [String: Any], let kind = body["kind"] as? String,
            canvasMessage(kind, body)
        {
            return
        }
        if page == .review, let body = message.body as? [String: Any], let kind = body["kind"] as? String,
            ["pick", "note", "send", "recommended", "unsend"].contains(kind)
        {
            guard shownVersion == nil else { return NSSound.beep() }   // an older version is read, not answered
            return answer(
                kind, point: body["point"] as? String ?? "",
                value: body[kind == "pick" ? "key" : "text"] as? String ?? "")
        }
        guard let body = message.body as? [String: Any], let line = (body["line"] as? NSNumber)?.intValue else {
            return
        }
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
        if !positioned, split.bounds.width > 700 {
            positioned = true
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        }
        // Split in a narrow pane squeezes the preview to a word per line: show the source until there's room.
        let isNarrow = split.bounds.width > 0 && split.bounds.width < 760
        if isNarrow != narrow {
            narrow = isNarrow
            mode.setToolTip(isNarrow ? String(localized: "Split (needs a wider pane)") : nil, forSegment: 1)
            applyMode()
        }
    }

    func textChanged() { rerender(after: .milliseconds(250)) }
    /// The theme changed: the preview takes its page colours again.
    func themeChanged() { rerender() }

    /// The page is built off the main thread (a long document, or mermaid's 3.5 MB script inlined), and not at all
    /// while only the source shows.
    func rerender(after delay: Duration = .zero) {
        renderTask?.cancel()
        guard !web.isHidden else {
            dirty = true
            return
        }
        dirty = false
        renderTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let text = shownVersion ?? editor.text, base = url.deletingLastPathComponent(), shown = shownVersion
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var page: (background: String, text: String)?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                let colors = CodeEditor.page
                page = (colors.background.hexString, colors.text.hexString)
            }
            let kind = self.page, sendTo = pageAuthor?.title, labels = canvasLabels, marking = marking
            let editLabels = canvasEditLabels, again = canvasModeScripts, chrome = canvasChromeLabels
            let themes =
                CanvasPage.Themes(rawValue: UserDefaults.standard.string(forKey: CanvasPage.themesKey) ?? "")
                ?? (dark ? .dark : .light)
            let canvasView = CanvasPage.View(
                themes: isDashboard ? (dark ? .dark : .light) : themes, writer: canvasWriter, dashboard: isDashboard)
            // An agent's Markdown page (a doc, slides) takes marks, and a doc shows what its agent's last turn changed.
            let agents = artifactBar != nil && (kind == .markdown || kind == .slides)
            let markLabels = pageMarkLabels,
                slideLabels = ["of": String(localized: "of"), "escEnds": canvasLabels.escEnds]
            let changed =
                shown == nil && kind == .markdown ? baseline.map { Artifacts.changedLines(from: $0, to: text) } : nil
            let noSource = String(localized: "Where it came from isn't said: ask its agent for a data-source.")
            if changed == nil, agents { onChanges?(0) }
            let (html, scripts) = await Task.detached { [page] () -> (String, [String]) in
                if kind == .html { return (text, []) }
                if kind == .canvas {
                    let snapshot = shown.flatMap(CanvasSnapshot.read) ?? CanvasSnapshot.live(json: text, folder: base)
                    let built = CanvasPage.build(
                        snapshot, folder: base, root: Self.projectRoot(of: base.path), view: canvasView)
                    let around = CanvasChrome.source(
                        themes: themes.rawValue, labels: chrome, floats: !canvasView.dashboard)
                    let edit = CanvasEdit.source(marks: built.marks, tweaks: built.tweaks, labels: labels)
                    let byHand = CanvasEditMode.source(tokens: built.tokens, labels: editLabels)
                    let dash = canvasView.dashboard ? [DashboardPage.source(noSource: noSource)] : []
                    return (
                        built.html, [CanvasScript.source(issues: built.issues), around, edit, byHand] + dash + again
                    )
                }
                if kind == .review {
                    let body = ReviewPage.body(Review(text), sendTo: sendTo)
                    return (
                        MarkdownHTML.page(body: body, baseURL: base, dark: dark, page: page) + ReviewPage.style,
                        [ReviewPage.script]
                    )
                }
                let body = MarkdownHTML.render(text, marking: true)
                var html = MarkdownHTML.page(body: body, baseURL: base, dark: dark, page: page)
                var scripts = [
                    MarkdownHTML.mermaid(for: text, dark: dark), MarkdownHTML.math(for: body), MarkdownHTML.scrollSync
                ]
                .compactMap { $0 }
                if kind == .slides {
                    let system = DesignSystem.dir(root: Self.projectRoot(of: base.path)).appendingPathComponent(
                        "tokens.json")
                    let tokens = Artifacts.small(system.path, limit: 1 << 20).map {
                        String(decoding: $0, as: UTF8.self)
                    }
                    html += SlidesPage.style + SlidesPage.tokens(tokens ?? "")
                    scripts.append(SlidesPage.script(labels: slideLabels))
                }
                guard agents else { return (html, scripts) }
                let marks = CanvasMark.read(Artifacts.small(base.appendingPathComponent(CanvasMark.file).path))
                html += PageMarks.style
                scripts += [
                    CanvasChrome.source(themes: "", labels: chrome, floats: false),
                    PageMarks.source(marks: marks, labels: markLabels)
                ]
                if let changed { scripts.append(PageMarks.changes(changed)) }
                return (html, scripts + again)
            }.value
            guard !Task.isCancelled else { return }
            // Keep the reader's place across re-renders, and the slide shown (numbers both, so the async call can't trap
            // on nil).
            let was =
                (try? await web.evaluateJavaScript("[window.scrollY, window.kelpAt ?? 0]", contentWorld: Self.world))
                as? [Double] ?? [0, 0]
            let scrollY = was.first ?? 0, slide = Int(was.last ?? 0)
            guard !Task.isCancelled else { return }
            // In Split, on the block being edited; the place it had otherwise.
            let place =
                currentMode == "split" && (kind == .markdown || kind == .slides)
                ? "kelpToLine(\(editor.cursor?.line ?? 1))"
                : kind == .slides ? "kelpGo(\(slide))" : "window.scrollTo(0, \(scrollY))"
            // A canvas is Kelp's own page: its boards sit in frames sandboxed without scripts (`CanvasPage`).
            links.load(
                html, baseURL: base, scripts: scripts + [place], world: Self.world, pageScripts: kind == .canvas,
                in: web)
        }
    }

    @objc private func modeChanged() { applyMode() }

    /// ⇧⌘V: source → split → preview → source (split is skipped while the pane is too narrow for it).
    func cycleMode() {
        var segment = (mode.selectedSegment + 1) % 3
        if segment == 1, narrow { segment = 2 }
        mode.selectedSegment = segment
        applyMode()
        if segment != 2 { editor.focus() }
    }

    private func applyMode() {
        let segment = mode.selectedSegment
        editor.view.isHidden = segment == 2
        web.isHidden = segment == 0 || (segment == 1 && narrow)
        formattingBar?.isHidden = segment == 2   // nothing to format in the preview
        onEditing?(segment != 2)
        placeSelectionBar()
        split.adjustSubviews()
        if segment == 1, !narrow { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
        if dirty, !web.isHidden { rerender() }
    }

    private func edit(_ format: (String, NSRange) -> (text: String, selection: NSRange)) {
        let result = format(editor.text, editor.selectedRange)
        editor.apply(text: result.text, selection: result.selection)
        editor.focus()
    }
    @objc func bold() { edit(MarkdownFormat.toggleBold) }
    @objc func italic() { edit(MarkdownFormat.toggleItalic) }
    @objc func code() { edit(MarkdownFormat.toggleCode) }
    @objc func bullets() { edit(MarkdownFormat.toggleBullet) }
    @objc func numbered() { edit(MarkdownFormat.toggleNumbered) }
    @objc func tasks() { edit(MarkdownFormat.toggleTask) }
    @objc private func table() { edit { MarkdownFormat.insertTable($0, $1, columns: 3, rows: 2) } }
    @objc private func headingPicked(_ popUp: NSPopUpButton) {
        let level = popUp.indexOfSelectedItem - 1   // past the button's face: Text, Heading 1…3
        guard level >= 0 else { return }
        edit { MarkdownFormat.heading($0, $1, level: level) }
    }
    @objc func link() {
        Task {
            guard let address = await prompt(String(localized: "Insert link"), "URL", initial: "https://") else {
                return
            }
            edit { MarkdownFormat.makeLink($0, $1, url: address) }
        }
    }
}
