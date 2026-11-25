import AppKit
import Core
import DesignKit
import KelpKit

/// The "artifacts:" tab (Window › Artifacts Overview): every page agents made, in every project, in one place. The
/// Artifacts panel shows one project's pages in a narrow column; this tab adds the room for pictures, the pages of
/// all projects, what waits for the user, and what they pinned or put away.
@MainActor
final class OverviewTab: KelpKit.TabContent {
    static let scheme = "artifacts"
    static let uri = "artifacts:"
    static var title: String { String(localized: "Artifacts Overview") }

    let uri: String
    let view: NSView
    private let controller: OverviewController
    var title: String { Self.title }
    var icon: NSImage? { .symbol("square.grid.2x2") }

    init(uri: String, app: AppModel) {
        self.uri = uri
        controller = OverviewController(model: OverviewModel(app: app))
        view = controller.view
    }
    func focus() { controller.focus() }
}

/// Lays the tab out (its bar, the sources, the grid or the list) and follows the model.
@MainActor
final class OverviewController: NSViewController {
    private static let listKey = "artifactsOverview.list"   // grid or list: a view preference of this Mac
    private static let defaults = UserDefaults.standard

    let model: OverviewModel
    private let sources: OverviewSourceList
    let grid: OverviewGrid
    let list: OverviewTable
    private let quickLook = OverviewQuickLook()
    private let facts = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private let search = NSSearchField()
    private lazy var views = CapsuleSegments(
        labels: [String(localized: "Grid"), String(localized: "List")], name: String(localized: "View"), target: self,
        action: #selector(viewChosen))
    private lazy var failureBar = FailureBar { [weak self] in self?.readAgain() }
    private lazy var changeBar = AgentChangeBar(model: model)
    private let empty = EmptyStateView()
    private let loading = LoadingView(rows: false, rowHeight: Metrics.row)
    private var shown = false

    init(model: OverviewModel) {
        self.model = model
        sources = OverviewSourceList(model: model)
        grid = OverviewGrid(model: model)
        list = OverviewTable(model: model)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var asList: Bool { Self.defaults.bool(forKey: Self.listKey) }

    override func loadView() {
        let title = NSTextField.label(OverviewTab.title, font: .ui(TextSize.body, weight: .semibold))
        facts.lineBreakMode = .byTruncatingTail
        facts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.placeholderString = String(localized: "Search")
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searched)
        search.widthAnchor.constraint(equalToConstant: 190).isActive = true
        views.controlSize = .small
        views.selectedSegment = asList ? 1 : 0
        let sync = TextButton(String(localized: "Sync…")) { [weak self] in
            if let model = self?.model { OverviewSync.ask(model) }
        }
        sync.toolTip = String(localized: "Save the pages on claude.ai whole on this Mac, to open without the network")
        let bar = Bar.content([title, facts], [sync, search, views])

        let sourceScroll = sources.table.plainList("s")
        sourceScroll.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let rule = NSBox()
        rule.boxType = .separator
        let content = NSView()
        for scroll in [grid.scroll, list.scroll] { content.pin(scroll) }
        empty.place(in: content)
        loading.place(in: content)
        let column = NSStackView(views: [failureBar, changeBar, content])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width   // the bars and the pages as wide as the column
        column.distribution = .fill
        // The bars are as tall as what they say; the pages take the rest.
        for bar in [failureBar, changeBar] { bar.setHuggingPriority(.defaultHigh, for: .vertical) }
        content.setContentHuggingPriority(.init(1), for: .vertical)
        let body = NSStackView(views: [sourceScroll, rule, column])
        body.spacing = 0
        body.alignment = .height
        let root = NSStackView(views: [bar, body])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .width
        // The bar keeps its height and the body takes the rest: a stack's default gravity left the body at its
        // fitting height, a few rows tall, until something laid the window out again.
        root.distribution = .fill
        body.setHuggingPriority(.init(1), for: .vertical)
        view = root

        grid.onOpen = { [weak self] in self?.open($0) }
        grid.collection.onReturn = { [weak self] in if let page = self?.grid.selected { self?.open(page) } }
        grid.collection.onSpace = { [weak self] in self?.lookAtChosen() }
        grid.collection.onDoubleClick = { [weak self] path in
            if let page = self?.grid.page(path) { self?.open(page) }
        }
        grid.collection.menuFor = { [weak self] path in
            guard let self, let page = grid.page(path) else { return nil }
            let menu = NSMenu()
            fill(menu, page)
            return menu
        }
        list.onOpen = { [weak self] in self?.open($0) }
        list.table.onSpace = { [weak self] in self?.lookAtChosen() }
        list.menuFor = { [weak self] page, menu in self?.fill(menu, page) }
        showView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [model] in
            Values(
                model.pages, model.source, model.find, model.pinned, model.styles, model.changesSeen, model.waiting,
                model.failures)
        } changed: { [weak self] _ in
            self?.reload()
        }
        // A chat starting or stopping, or moving to another page, changes the faces and the "is editing" lines.
        track(owner: self, now: false) { [model] in
            PageAgents.watched(model.app)
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [model] in
            model.pictures.images.count
        } changed: { [weak self] _ in
            self?.grid.refreshPictures()
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true
        model.start()
        if model.waiting, model.pages.isEmpty { loading.wait(String(localized: "Reading the pages…")) }
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        model.stop()
        quickLook.close()
    }

    func focus() {
        view.window?.makeFirstResponder(asList ? list.table as NSView : grid.collection)
    }

    // MARK: Showing

    private func reload() {
        let pages = model.pages
        let projects = Set(pages.map(\.repo)).count
        facts.stringValue =
            pages.isEmpty
            ? "" : String(localized: "\(pages.count) pages · \(projects) projects")
        sources.show(pages)
        let shown = OverviewPages.shown(
            pages, in: model.source, pinned: model.pinned, busy: model.busy, find: model.find, words: model.words)
        grid.show(OverviewPages.sections(shown, pinned: model.pinned, source: model.source, now: Date()))
        list.show(shown)
        failureBar.show(model.failures.isEmpty ? nil : model.failures.joined(separator: "; "))
        changeBar.show(model.agentChange)
        if !pages.isEmpty || !model.waiting { loading.show(nil) }
        empty.show(emptyTitle(pages: pages, shown: shown), symbol: "doc.richtext", text: emptyText(pages: pages))
    }

    private func emptyTitle(pages: [OverviewPage], shown: [OverviewPage]) -> String? {
        guard shown.isEmpty, !(model.waiting && pages.isEmpty) else { return nil }
        if pages.isEmpty { return String(localized: "No Artifacts Yet") }
        if !model.find.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "No Pages Found") }
        return switch model.source {
        case .waiting: String(localized: "Nothing Waits for You")
        case .now: String(localized: "No Agent Works on a Page")
        case .pinned: String(localized: "No Pinned Pages")
        case .archive: String(localized: "The Archive Is Empty")
        case .tag: String(localized: "No Pages with This Tag")
        default: String(localized: "No Pages")
        }
    }
    private func emptyText(pages: [OverviewPage]) -> String? {
        if pages.isEmpty { return String(localized: "Pages agents make show here, from every project.") }
        return switch model.source {
        case .waiting: String(localized: "Reviews to answer, marks to check and agents’ questions show here.")
        case .pinned: String(localized: "Pin a page from its menu to keep it on top.")
        case .archive: String(localized: "Pages moved to the archive leave the other lists, and come back from here.")
        default: nil
        }
    }

    private func showView() {
        grid.scroll.isHidden = asList
        list.scroll.isHidden = !asList
    }

    @objc private func viewChosen() {
        Self.defaults.set(views.selectedSegment == 1, forKey: Self.listKey)
        let chosen = asList ? grid.selected : list.selected
        showView()
        if let chosen {   // the chosen page stays chosen in the other view
            if asList, let row = list.pages.firstIndex(where: { $0.id == chosen.id }) {
                list.table.selectRowIndexes([row], byExtendingSelection: false)
                list.table.scrollRowToVisible(row)
            }
        }
        focus()
    }
    @objc private func searched() { model.find = search.stringValue }

    private func readAgain() { for id in model.watching { model.app.watchAgain(.artifacts, id) } }

    // MARK: Acting

    private var chosen: OverviewPage? { asList ? list.selected : grid.selected }

    private func open(_ page: OverviewPage) {
        quickLook.close()
        let app = model.app
        ArtifactActions.open(app, page.item)
        Task {
            if await ArtifactSeen.mark([page.item.target], app) { self.reload() }
        }
    }

    private func lookAtChosen() {
        guard let page = chosen else { return NSSound.beep() }
        quickLook.toggle(page.item, title: model.title(page))
    }

    private func fill(_ menu: NSMenu, _ page: OverviewPage) {
        ArtifactActions.addItems(
            to: menu, model.app, page.item, open: { [weak self] _ in self?.open(page) },
            quickLook: { [weak self] in
                guard let self else { return }
                quickLook.toggle(page.item, title: model.title(page))
            }, keeping: model.keeping(page))
    }
}

/// Over the pages, what an agent last did to them, until the user closes it: "Claude archived 7 pages and tagged 23",
/// Show (those pages), Undo (puts them back as they were) and ✕.
@MainActor
final class AgentChangeBar: NSStackView {
    private let model: OverviewModel
    private let face = NSImageView()
    private let line = NSTextField.label("", font: .ui(TextSize.caption))
    private var change: OverviewAgentChange?

    init(model: OverviewModel) {
        self.model = model
        super.init(frame: .zero)
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let show = TextButton(
            String(localized: "Show"),
            onClick: { [weak self] in
                if let change = self?.change { self?.model.source = .changed(by: change.session) }
            })
        let undo = TextButton(
            String(localized: "Undo"),
            onClick: { [weak self] in
                if let change = self?.change { self?.model.undo(change) }
            })
        let close = IconButton(.symbol("xmark"), tip: String(localized: "Close")) { [weak self] in
            if let change = self?.change { self?.model.dismiss(change) }
        }
        for button in [show, undo, close] as [NSView] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        setViews([face, line, NSView(), show, undo, close], in: .leading)
        spacing = Metrics.gap
        edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ change: OverviewAgentChange?) {
        self.change = change
        if let change {
            let session = model.app.session(change.session)
            let agent = session?.agent.map { model.app.catalog.name($0) } ?? String(localized: "An agent")
            face.image = session?.agent.flatMap { model.app.catalog.icon($0, size: Metrics.iconSmall) }
            line.stringValue = Self.text(agent: agent, change)
        }
        guard isHidden != (change == nil) else { return }
        crossfade()
        isHidden = change == nil
    }

    /// "Claude: 1 page archived, 2 pages tagged", each count in its own words so each takes its plural.
    static func text(agent: String, _ change: OverviewAgentChange) -> String {
        var parts: [String] = []
        if change.archived > 0 { parts.append(String(localized: "\(change.archived) pages archived")) }
        if change.tagged > 0 { parts.append(String(localized: "\(change.tagged) pages tagged")) }
        return "\(agent): " + parts.joined(separator: ", ")
    }
}
