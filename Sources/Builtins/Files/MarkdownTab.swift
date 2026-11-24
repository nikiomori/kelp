import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import Markdown
import WebKit

/// The tab for a Markdown file: the editor, a live preview, or both, with a formatting bar for the specs and plans you
/// write for agents. It also shows an agent's HTML page (a design, a dashboard) as it is, and an agent's slides, cut
/// into 16:9 slides.
@MainActor
final class MarkdownTab: NSViewController, WKScriptMessageHandler {
    let editor: CodeEditor
    let url: URL
    let app: AppModel
    let web = DropWebView()
    let links: PreviewLinks
    /// The script world where Kelp's scripts for the preview run, and the only world `kelpSync` listens to. The page's
    /// own scripts don't run (`PreviewLinks`).
    static let world = WKContentWorld.world(name: "kelp")
    private let mode = CapsuleSegments(
        labels: [String(localized: "Edit"), String(localized: "Split"), String(localized: "Preview")],
        name: String(localized: "Mode"))
    let split = NSSplitView()
    var renderTask: Task<Void, Never>?
    /// The parts the last loaded page was built from, kept when its body can be replaced in place (`Swap`).
    var swappable: Swap?
    /// Set when the text was edited while the preview was hidden (Edit mode), so the preview renders when it shows.
    var dirty = false
    /// Whether the tab opens in Preview, as documents meant to be read (Kelp's help) do.
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
    /// Until this time the source is following the preview's scroll, so it doesn't scroll the preview back.
    private var followingPreview = Date.distantPast
    /// Called with whether the source is on screen to edit, because the status bar's cursor means nothing in the
    /// preview.
    var onEditing: ((Bool) -> Void)?
    /// Writes the file to disk, because a review's picks are answers the agent reads from there.
    var saveFile: (() async -> Bool)?
    let page: Page
    /// On a canvas, the `kelp artifact check` that waits for the next drawing, and what the last check found.
    var pendingCheck: String?
    var checkIssues: [String]?
    /// On a canvas, whether a click on a board puts a mark on it (Mark in the bar), and whether the boards are being
    /// presented. `onPresentEnded` hears when presenting ends (Esc on the page).
    var marking = false, presentingBoards = false
    /// On a canvas, whether a click chooses an element to change by hand (Edit in the bar), and the chosen element (its
    /// board and data-id). That element is chosen again after the canvas is redrawn.
    var editing = false
    var chosen: (board: String, id: String)?
    /// The elements changed by hand since the last pause, and the wait for the next one (`keepHandEdit`).
    var handEdited: Set<String> = [], markQueue: [Int] = [], followingAuthor = false   // the queue: `followAuthor`
    var handSteps: (undo: [HandStep], redo: [HandStep]) = ([], [])   // for ⌘Z and ⇧⌘Z (`undoHandEdit`)
    var lastRewrite: Task<Void, Never>?   // board rewrites one after another (`rewrite`)
    var canvasLanguage = "as"   // ⋯ › View's As Is, +40% or RTL, kept across drawings (`viewMenu`)
    var takesRows = false   // an element shows a table's column (`DataRows`): For Each Row… applies
    let handEditRest = Debounce()
    /// The bar for checking the marks an agent's turn handed back.
    lazy var reviewBar = MarkReviewBar { [weak self] call in self?.runJS(call) }
    /// The player and timeline under a motion page.
    lazy var motionStudio = makeMotionStudio()
    /// On a canvas, the zoom set by hand (nil when it's fitted to the pane), and the agent writing it now (the board
    /// being written gets the ring).
    var canvasZoom: Double?
    var canvasWriter: String? {
        didSet { if canvasWriter != oldValue, page == .canvas { rerender() } }
    }
    var onPresentEnded: (() -> Void)?
    /// Whether the canvas is a dashboard, which is drawn as a page of data (`CanvasPage.View.dashboard`).
    var isDashboard = false {
        didSet { if isDashboard != oldValue { rerender() } }
    }
    /// On a doc, the page as it was when the agent's last turn started, so the preview can mark what the turn changed.
    /// `onChanges` hears how many blocks it changed.
    var baseline: String? {
        didSet { if baseline != oldValue { rerender() } }
    }
    var onChanges: ((Int) -> Void)?
    /// Called when the page turns Mark on by itself (with the Mark button under a selection).
    var onPageMode: ((CanvasMode) -> Void)?
    /// An older version of the page (`ArtifactBar`). It shows in the preview instead of the file, and it can't be
    /// answered or edited.
    private(set) var shownVersion: String?

    var artifactBar: ArtifactBar?
    /// Gets the title and kind of a page an agent made, for the tab.
    var onPageTitle: ((String?, Artifacts.Kind?) -> Void)?
    /// Gets what the canvas's check found each time the canvas is drawn, for the bar to show.
    var onCheck: (([String]) -> Void)?

    /// Returns the view over the tab. A page an agent made gets its own bar (its kind, versions and chat) where the
    /// path would be. Any other file gets `crumbs`.
    func header(else crumbs: NSView) -> NSView {
        guard ArtifactBar.isPage(url.path) else { return crumbs }
        let bar = ArtifactBar(app: app, path: url.path, markdown: self)
        artifactBar = bar
        return bars(bar.view, reviewBar.bar)
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

    /// Restores an older version: the file's text becomes `text`, and the file is saved.
    @discardableResult func restore(_ text: String) async -> Bool {
        if page == .canvas, let snapshot = CanvasSnapshot.read(text) { return await restoreCanvas(snapshot) }
        editor.apply(text: text, selection: NSRange(location: 0, length: 0))
        return await saveFile?() ?? false
    }

    /// Prints the page as the preview shows it, through the system's print panel (which can also save a PDF).
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

    /// An icon button for the bar and for the selection bar.
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
        // The heading styles are a menu on one button (the menu's first item is the button's face).
        let heading = PointerPopUpButton(frame: .zero, pullsDown: true)   // greys under the pointer, like the icons
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
                heading, gap(), tool("bold", keyed(String(localized: "Bold"), "markdown.bold"), #selector(bold)),
                tool("italic", keyed(String(localized: "Italic"), "markdown.italic"), #selector(italic)),
                tool(
                    "chevron.left.forwardslash.chevron.right", keyed(String(localized: "Code"), "markdown.code"),
                    #selector(code)),
                tool("link", keyed(String(localized: "Link"), "markdown.link"), #selector(link)), gap(),
                tool("list.bullet", keyed(String(localized: "Bulleted List"), "markdown.bullets"), #selector(bullets)),
                tool(
                    "list.number", keyed(String(localized: "Numbered List"), "markdown.numbered"), #selector(numbered)),
                tool("checklist", keyed(String(localized: "Task List"), "markdown.tasks"), #selector(tasks)),
                tool("tablecells", keyed(String(localized: "Table"), "markdown.table"), #selector(table))
            ], in: .leading)
        formatting.spacing = Metrics.iconGap
        let bar = Bar.content([formatting])
        formattingBar = bar
        split.isVertical = true
        split.dividerStyle = .thin
        web.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        web.navigationDelegate = links
        setUpPointer()
        web.configuration.userContentController.add(WeakHandler(self), contentWorld: Self.world, name: "kelpSync")
        split.addArrangedSubview(editor.view)
        split.addArrangedSubview(DeviceStage(web))   // the page, or a device's screen (`DeviceControls`)
        editor.view.clipsToBounds = true
        // An agent's page has its own bar, whose ⋯ menu holds the modes (⇧⌘V cycles them), so the page gets one bar,
        // not two. Any other file gets the formatting bar on top, which hides in Preview because there is nothing to
        // format there, and the modes sit in the status bar.
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
            view = page == .motion ? MotionSplit(stage: split, studio: motionStudio.view) : stacked(split)
        }
        view.addSubview(selectionBar)   // over the text, placed by frame
        let before = editor.onSelection   // the breadcrumbs and the conflict bar follow the selection too
        editor.onSelection = { [weak self] in
            before?()
            self?.placeSelectionBar()
        }
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
    /// Connects the file's status bar. The status bar is told whether the source is on screen, and it gets the Edit /
    /// Split / Preview control, unless this is an agent's page, which has them in the ⋯ menu of its own bar. Call it
    /// after `header`, which decides whether this is an agent's page.
    func attach(_ bar: EditorStatusBar) {
        onEditing = { [weak bar] in bar?.editing = $0 }
        bar.editing = mode.selectedSegment != 2
        if artifactBar == nil { bar.show(modes: mode) }
    }
    private lazy var selectionBar = MarkdownSelectionBar(
        target: self,
        items: [
            ("bold", keyed(String(localized: "Bold"), "markdown.bold"), #selector(bold)),
            ("italic", keyed(String(localized: "Italic"), "markdown.italic"), #selector(italic)),
            (
                "chevron.left.forwardslash.chevron.right", keyed(String(localized: "Code"), "markdown.code"),
                #selector(code)
            ),
            ("link", keyed(String(localized: "Link"), "markdown.link"), #selector(link))
        ])
    /// A formatting button's tooltip, with its command's key as it stands.
    private func keyed(_ title: String, _ id: String) -> String { app.extensions.hint(title, id) }

    /// Shows the selection bar over the selection once it's made (not while the mouse is still dragging), and hides it
    /// when there's no selection.
    private func placeSelectionBar() {
        guard NSEvent.pressedMouseButtons == 0, page != .html, page != .canvas, !editor.view.isHidden,
            let selection = editor.selectionRect
        else {
            if !selectionBar.isHidden { selectionBar.crossfade() }   // it fades away as it came
            return selectionBar.isHidden = true
        }
        selectionBar.show(over: view.convert(selection, from: editor.view), in: view)
    }

    /// Shows the preview and sends keys to it, so a canvas being presented steps with ← →.
    func focusPreview() {
        if modeSegment != 2 { modeSegment = 2 }
        view.window?.makeFirstResponder(web)
    }

    /// Runs a script on the page without waiting for its result, because the async evaluateJavaScript traps on an
    /// undefined result.
    func runJS(_ js: String) { web.evaluateJavaScript(js, in: nil, in: Self.world, completionHandler: nil) }

    @objc private func scrolled() {
        if !selectionBar.isHidden { placeSelectionBar() }
        guard currentMode == "split", !web.isHidden, Date() > followingPreview else { return }
        runJS("kelpToLine(\(editor.topLine))")
    }

    /// Handles messages from Kelp's scripts beside the preview's page (in `world`, since the page's own scripts don't
    /// run). Canvas and review messages go to their own handlers. Otherwise the page scrolled to a line (the source
    /// follows), or a line was double-clicked (the cursor goes there).
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL != false else { return }
        let agents =
            page == .canvas || page == .motion || (artifactBar != nil && (page == .markdown || page == .slides))
        if agents, let body = message.body as? [String: Any], let kind = body["kind"] as? String,
            canvasMessage(kind, body)
        {
            return
        }
        if page == .review, let body = message.body as? [String: Any], let kind = body["kind"] as? String,
            ["pick", "note", "send", "recommended", "unsend"].contains(kind)
        {
            guard shownVersion == nil else { return NSSound.beep() }   // an older version is read-only
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
    /// Called when the theme changes, so the preview picks up the new page colours.
    func themeChanged() { rerender() }

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
}
