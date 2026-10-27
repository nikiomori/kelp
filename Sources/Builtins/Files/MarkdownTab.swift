import AppKit
import WebKit
import Markdown
import EditorKit
import KelpKit

/// A Markdown file: editor, live preview, or both, with a formatting bar for specs and plans you write for agents.
@MainActor
final class MarkdownTab: NSViewController {
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

    /// A compact icon button: the strip's and the selection bar's.
    static func toolButton(_ sym: String, _ tip: String, _ sel: Selector, target: AnyObject) -> NSButton {
        let x = NSButton(image: .symbol(sym, tip), target: target, action: sel)
        x.isBordered = false
        x.imagePosition = .imageOnly
        x.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        x.contentTintColor = .secondaryLabelColor
        x.toolTip = tip
        x.widthAnchor.constraint(equalToConstant: 26).isActive = true
        x.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return x
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
        let heading = NSPopUpButton(frame: .zero, pullsDown: true)
        heading.isBordered = false
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
        formatting.spacing = 0
        let bar = NSStackView(views: [formatting, NSView(), mode])
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 8)
        split.isVertical = true; split.dividerStyle = .thin
        web.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        web.navigationDelegate = links
        split.addArrangedSubview(editor.view); split.addArrangedSubview(web)
        editor.view.clipsToBounds = true
        view = stacked(bar, split)
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
        guard NSEvent.pressedMouseButtons == 0, !editor.view.isHidden, let r = editor.selectionRect else { return selectionBar.isHidden = true }
        selectionBar.show(over: view.convert(r, from: editor.view), in: view)
    }

    @objc private func scrolled() { if !selectionBar.isHidden { placeSelectionBar() } }

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

    /// The page is built off the main thread (a long document, or mermaid's 3.5 MB script inlined), and not at all
    /// while only the source shows.
    private func rerender(after delay: Duration = .zero) {
        renderTask?.cancel()
        guard !web.isHidden else { dirty = true; return }
        dirty = false
        renderTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let text = editor.text, base = url.deletingLastPathComponent(), dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let html = await Task.detached {
                MarkdownHTML.page(body: MarkdownHTML.render(text), baseURL: base, dark: dark) + (MarkdownHTML.mermaid(for: text, dark: dark) ?? "")
            }.value
            guard !Task.isCancelled else { return }
            // Keep the reader's place across re-renders (scrollY is always a number, so the async call can't trap on nil).
            let y = (try? await web.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            guard !Task.isCancelled else { return }
            web.loadHTMLString(html + "<script>window.scrollTo(0, \(y))</script>", baseURL: base)
        }
    }

    @objc private func modeChanged() { applyMode() }

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
