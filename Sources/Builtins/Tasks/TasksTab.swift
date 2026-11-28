import AppKit
import Core
import DesignKit
import KelpKit

/// The "tasks:" tab (Window › Tasks): every project's tasks in one place, laid out as Artifacts Overview is — its bar,
/// the column of lists on the left, the rows on the right. The lines themselves live on the projects' pages; the tab
/// only gathers them.
@MainActor
final class TasksTab: KelpKit.TabContent {
    static let uri = "tasks:"
    static var title: String { String(localized: "Tasks") }

    let uri: String
    let view: NSView
    private let controller: TasksController
    var title: String { Self.title }
    var icon: NSImage? { .symbol("checklist") }

    init(uri: String, app: AppModel) {
        self.uri = uri
        controller = TasksController(model: TasksModel(app: app))
        view = controller.view
    }
    func focus() { controller.focus() }
    var canGroup: Bool { controller.list.selected.count > 1 }
    func group() { controller.groupChosen() }
}

/// Lays the tab out (its bar, the lists, the rows) and follows the model.
@MainActor
final class TasksController: NSViewController {
    let model: TasksModel
    let sources: TaskSourceList
    let list: TaskRows
    let board: TaskBoard
    private lazy var views = CapsuleSegments(
        labels: [String(localized: "List"), String(localized: "Board")], name: String(localized: "View"), target: self,
        action: #selector(viewChosen))
    private let facts = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private let search = NSSearchField()
    private lazy var failureBar = FailureBar { [weak self] in self?.readAgain() }
    private lazy var proposals = TaskProposalBar(model: model)
    let empty = EmptyStateView()
    private let loading = LoadingView(rows: true, rowHeight: Metrics.rowTwoLine)
    private var shown = false
    lazy var quickLook = QuickLookList { [weak self] in
        self?.list.chosen.map { URL(fileURLWithPath: $0.pageFile) }
    }

    init(model: TasksModel) {
        self.model = model
        sources = TaskSourceList(model: model)
        list = TaskRows(model: model)
        board = TaskBoard(model: model)
        super.init(nibName: nil, bundle: nil)
        list.table.onSpace = { [weak self] in self?.togglePreview() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField.label(TasksTab.title, font: .ui(TextSize.body, weight: .semibold))
        facts.lineBreakMode = .byTruncatingTail
        facts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.placeholderString = String(localized: "Search")
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searched)
        search.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let write = TextButton(String(localized: "New Task…")) { [weak self] in
            guard let self else { return }
            model.app.part { QuickEntry(app: model.app) }.show(repo: model.currentProject)
        }
        write.toolTip = String(localized: "Write a task down (⌃⌥⌘T from anywhere)")
        views.controlSize = .small
        let bar = Bar.content([title, facts], [write, search, views])

        let sourceScroll = sources.table.plainList("s")
        let rule = NSBox()
        rule.boxType = .separator
        let content = NSView()
        content.pin(list.scroll)
        content.pin(board.scroll)
        empty.place(in: content)
        loading.place(in: content)
        let root = NSView()
        // The bars over the rows are as tall as what they say, and take no room while hidden.
        let bars = NSStackView(views: [failureBar, proposals])
        bars.orientation = .vertical
        bars.spacing = 0
        bars.detachesHiddenViews = true
        // With both bars hidden it takes no height, so the rows start at the top.
        bars.setHuggingPriority(.required, for: .vertical)
        for part in [failureBar, proposals] { part.widthAnchor.constraint(equalTo: bars.widthAnchor).isActive = true }
        for part in [bar, sourceScroll, rule, bars, content] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(part)
        }
        // By hand, edge to edge, as Artifacts Overview is: the bar on top, the lists at their width on the left.
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sourceScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            sourceScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sourceScroll.widthAnchor.constraint(equalToConstant: 210),
            rule.topAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: sourceScroll.trailingAnchor),
            rule.widthAnchor.constraint(equalToConstant: 1),
            bars.topAnchor.constraint(equalTo: bar.bottomAnchor),
            bars.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            bars.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: bars.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The lines, the chats' states (a mark turns), the list chosen and the words searched.
        // The list kept in the window's state, once it is read.
        track(owner: self) { [model] in
            model.app.uiState[TasksModel.sourceKey]?.string
        } changed: { [model] in
            model.restore($0)
        }
        track(owner: self) { [model] in
            Values(model.rows, model.source, model.find, model.failures, model.waiting, model.board)
        } changed: { [weak self] _ in
            self?.reload()
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true
        model.start()
        if model.waiting, model.rows.isEmpty { loading.wait(String(localized: "Reading the tasks…")) }
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        model.stop()
    }

    func focus() { view.window?.makeFirstResponder(list.table) }

    /// ⌥⌘G: the chosen lines become one task, the first growing into a page with the others as its plan.
    func groupChosen() { TaskActions.group(model.app, list.selected) }

    private func reload() {
        let rows = model.rows
        let open = rows.count { $0.task.state == .open && $0.task.depth == 0 }
        let projects = Set(rows.map(\.repo)).count
        facts.stringValue = open == 0 ? "" : String(localized: "\(open) open · \(projects) projects")
        sources.show(rows)
        let sections = TaskViews.sections(
            rows, model.source, find: model.find, projectName: model.projectName,
            day: { day in
                TaskRows.day(day)
            })
        // The logbook is a list of days: it has no board.
        let asBoard = model.board && model.source != .journal
        views.selectedSegment = model.board ? 1 : 0
        views.setEnabled(model.source != .journal, forSegment: 1)
        list.scroll.isHidden = asBoard
        board.scroll.isHidden = !asBoard
        let columns =
            asBoard
            ? TaskViews.board(rows, model.source, find: model.find, projectName: model.projectName, inPR: model.inPR)
            : []
        if asBoard { board.show(columns) } else { list.show(sections) }
        failureBar.show(model.failures.isEmpty ? nil : model.failures.joined(separator: "; "))
        proposals.show(rows)
        if !rows.isEmpty || !model.waiting { loading.show(nil) }
        // A board keeps its empty columns, unless a search found nothing.
        let found = !searching || columns.contains { !$0.rows.isEmpty }
        let none = (asBoard ? rows.isEmpty || !found : sections.isEmpty) && !(model.waiting && rows.isEmpty)
        let record = NSButton(title: String(localized: "New Task…"), target: self, action: #selector(newTask))
        empty.show(
            none ? emptyTitle(rows) : nil, symbol: "checklist", text: none ? emptyText(rows) : nil,
            buttons: rows.isEmpty || model.source == .inbox ? [record] : [])
    }

    private var searching: Bool { !model.find.trimmingCharacters(in: .whitespaces).isEmpty }

    private func emptyTitle(_ rows: [TaskRow]) -> String {
        if rows.isEmpty { return String(localized: "No Tasks Yet") }
        if searching { return String(localized: "No Tasks Found") }
        return switch model.source {
        case .inbox: String(localized: "The Inbox Is Empty")
        case .now: String(localized: "No Agent Works on a Task")
        case .waiting: String(localized: "Nothing Waits for You")
        case .journal: String(localized: "The Logbook Is Empty")
        case .tag: String(localized: "No Tasks with This Tag")
        case .all, .project: String(localized: "No Open Tasks")
        }
    }
    private func emptyText(_ rows: [TaskRow]) -> String? {
        if rows.isEmpty { return String(localized: "Write the first one down: ⌃⌥⌘T from anywhere.") }
        return switch model.source {
        case .inbox: String(localized: "What you write down with ⌃⌥⌘T lands here, until you move it onto a page.")
        case .now: String(localized: "Hand a task to an agent with ▶: it shows here while the agent works.")
        case .waiting: String(localized: "Agents’ questions, work to review and their proposals show here.")
        case .journal: String(localized: "Tasks you close or cancel stay here.")
        default: nil
        }
    }

    @objc private func viewChosen() { model.board = views.selectedSegment == 1 }
    @objc private func newTask() { model.app.part { QuickEntry(app: model.app) }.show(repo: model.currentProject) }
    @objc private func searched() { model.find = search.stringValue }
    private func readAgain() { for id in model.watching { model.app.watchAgain(.tasks, id) } }
}
