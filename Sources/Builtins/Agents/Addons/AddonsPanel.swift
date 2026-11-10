import AppKit
import Core
import DesignKit
import KelpKit

/// Skills & MCP: what the chat looked at last in the workspace on screen gets besides the prompt (its skills, MCP
/// servers and instruction files, as it reported them at its start), or what a new chat there would get when it has no
/// record. Read when the panel shows, and again when the workspace or the chat changes. Read-only for now.
@MainActor
final class AddonsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let app: AppModel
    private let table = NSTableView()
    private let empty = EmptyStateView()
    private let face = NSImageView()
    private let chatTitle = NSTextField(labelWithString: "")
    private let counts = NSTextField(labelWithString: "")
    private lazy var summary = NSStackView(views: [counts])
    private lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in
        self?.showMore()
    }
    private var addons: Addons?
    private var lines: [AddonLine] = []
    /// The groups folded or unfolded by hand: view state, not kept.
    private var toggled: Set<AddonGroup> = []
    private var shown = false
    private var loading: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = table.plainList("addons")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        // The inspector's own title names the panel: its bar names the chat, as Source Control's names the branch.
        let header = Bar.panel([face, chatTitle], [more])
        chatTitle.font = .ui(TextSize.row, weight: .medium)
        chatTitle.lineBreakMode = .byTruncatingTail
        chatTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        counts.font = .uiDigits(TextSize.caption)
        counts.textColor = .secondaryLabelColor
        counts.lineBreakMode = .byTruncatingTail
        counts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        summary.isHidden = true
        // A stack: the summary takes no room while it's hidden.
        let column = NSStackView(views: [header, summary, scroll])
        column.orientation = .vertical
        column.spacing = 0
        for part in column.arrangedSubviews { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let root = NSView()
        root.pin(column)
        empty.place(in: root, under: header)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        track(owner: self) { [weak self] in
            [self?.app.workbench.workspaceId, self?.chat?.id]
        } changed: { [weak self] _ in
            self?.reload()
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true
        reload()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        loading?.cancel()
    }

    /// The agent chat looked at last in the workspace on screen (the focused tab when it's one), else its newest.
    private var chat: Session? {
        let workspace = app.workbench.workspaceId
        if let last = app.workbench.lastSession.flatMap(app.session), last.worktreeId == workspace, last.isAgent {
            return last
        }
        return app.sessions.last { $0.worktreeId == workspace && $0.isChat && $0.isAgent && $0.status != .exited }
    }

    // MARK: Loading

    private func reload() {
        guard shown else { return }
        loading?.cancel()
        guard let workspace = app.workbench.workspaceId else { return show(nil, error: nil, chat: nil) }
        let chat = chat
        loading = Task { [weak self, app] in
            let answer = await app.tryCall(AddonsList(worktreeId: workspace, session: chat?.id))
            guard !Task.isCancelled else { return }
            self?.show(answer.value, error: answer.error, chat: chat)
        }
    }

    private func show(_ value: Addons?, error: String?, chat: Session?) {
        addons = value
        if let error {
            empty.showError(String(localized: "Couldn’t read the skills and servers"), text: error)
        } else {
            empty.show(
                (value?.items ?? []).isEmpty ? String(localized: "Nothing here yet") : nil, symbol: "powerplug",
                text: String(localized: "What agents get besides the prompt: skills, MCP servers, instruction files."))
        }
        let items = value?.items ?? []
        summary.isHidden = items.isEmpty || error != nil
        // The chat when the list is its own record (or nothing came back), else what a new one would get.
        let named = value.map { $0.chat ? chat : nil } ?? chat
        face.image = named.flatMap { app.catalog.icon($0.agent, size: Metrics.appIcon) }
        face.isHidden = face.image == nil
        chatTitle.stringValue =
            named.map(app.catalog.displayName) ?? (value == nil ? "" : String(localized: "What a new chat gets"))
        counts.stringValue = AddonGroups.summary(items)
        relist()
    }

    private func relist() {
        lines = AddonGroups.lines(addons?.items ?? [], toggled: toggled)
        table.reloadData()
    }

    private func showMore() {
        let menu = NSMenu()
        menu.add(String(localized: "Refresh")) { [weak self] in self?.reload() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    @objc private func clicked() {
        guard lines.indices.contains(table.clickedRow), case .group(let g, _, _) = lines[table.clickedRow] else {
            return
        }
        if toggled.remove(g) == nil { toggled.insert(g) }
        relist()
    }

    // MARK: Table view

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch lines[row] {
        case .section: TextSize.of(Metrics.rowSection)
        case .problem: TextSize.of(Metrics.rowTwoLine)
        case .group, .item: TextSize.of(Metrics.row)
        }
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let rows = AddonRows(app: app)
        return switch lines[row] {
        case .section(let section, let count): rows.section(section, count: count)
        case .group(let g, let count, let open): rows.group(g, count: count, open: open)
        case .item(let addon, let nested): rows.item(addon, nested: nested)
        case .problem(let addon): rows.problem(addon)
        }
    }
}
