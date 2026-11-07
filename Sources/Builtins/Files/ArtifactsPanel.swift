import AppKit
import Core
import DesignKit
import KelpKit

/// The pages agents made in the workspace on screen (`.kelp/artifacts`, read by the daemon while the panel shows),
/// newest first: what each is, who made it, how far a review is answered. A file opens in a tab; a page on an agent's
/// own service in the user's browser, which is signed in to it (Kelp's tabs aren't).
@MainActor
final class ArtifactsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let symbols = [
        "doc": "doc.text", "review": "checklist", "slides": "play.rectangle", "design": "square.grid.2x2",
        "dashboard": "chart.bar"
    ]
    private let app: AppModel
    private let table = NSTableView()
    private let empty = EmptyStateView()
    private var rows: [ArtifactItem] = []
    private lazy var watched = Watched(.artifacts, in: app)
    private var shown = false

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("a"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(open)
        table.menu = NSMenu()
        table.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // No bar of its own: the inspector's title names it, and there's nothing to do over the list.
        let content = NSView()
        content.pin(scroll)
        empty.place(in: content)
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The workspace on screen, its pages, and its chats: who made each page, and whether it's still writing.
        track(owner: self) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] _ in
            self?.watchShown()
        }
        track(owner: self) { [app] in
            app.latest(ArtifactsEvent.self, app.workbench.workspaceId ?? "")?.items
        } changed: { [weak self] _ in
            self?.reload()
        }
        track(owner: self) { [app] in
            app.sessions.map { "\($0.id)\($0.status)" }
        } changed: { [weak self] _ in
            self?.reload()
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true
        watchShown()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false
        watchShown()
    }
    private func watchShown() {
        watched.key = shown ? app.workbench.workspaceId : nil
        reload()
    }

    private func reload() {
        let list = app.latest(ArtifactsEvent.self, app.workbench.workspaceId ?? "")?.items
        rows = list ?? []
        empty.show(
            list != nil && rows.isEmpty ? String(localized: "No artifacts yet") : nil, symbol: "doc.richtext",
            text: String(localized: "Pages agents make show here."), buttons: [makeButton])
        table.reloadData()
    }

    /// Make's choices, as on the start page and in "+": the default agent starts with the line, for the user to finish.
    private lazy var makeButton = NSButton(title: String(localized: "Make…"), target: self, action: #selector(showMake))
    @objc private func showMake() {
        makeMenu(app).popUp(positioning: nil, at: NSPoint(x: 0, y: makeButton.bounds.height + 4), in: makeButton)
    }

    /// Saved in the last two minutes while its chat works: the agent is writing it.
    private func writing(_ item: ArtifactItem) -> Bool {
        guard let modified = item.modified, app.session(item.session ?? "")?.status == .working else { return false }
        return Date().timeIntervalSince1970 - modified < 120
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row], session = item.session.flatMap(app.session)
        let symbol = Self.symbols[item.type] ?? "link"
        let icon = NSImageView(image: .symbol(symbol))
        icon.symbolConfiguration = .chrome()
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: item.title)
        name.font = .ui(12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let progress = item.points.flatMap { points in
            points == 0 ? nil : String(localized: "\(item.answered ?? 0) of \(points) answered")
        }
        var about = [
            session.map { app.catalog.name($0.agent) }, session?.status == .exited ? String(localized: "ended") : nil,
            progress
        ]
        if let link = item.url { about.append(URL(string: link)?.host) }
        let detail = NSTextField(labelWithString: about.compactMap { $0 }.joined(separator: " · "))
        detail.font = .ui(11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = detail.stringValue.isEmpty   // the name alone, in the middle of the row
        let text = NSStackView(views: [name, detail])
        text.detachesHiddenViews = true
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        let end: NSView
        if writing(item) {
            let ring = NSProgressIndicator()
            ring.style = .spinning
            ring.controlSize = .small
            ring.startAnimation(nil)
            ring.toolTip = String(localized: "The agent is writing it")
            end = ring
        } else {
            let when = NSTextField(labelWithString: shortAgo(Date(timeIntervalSince1970: item.created)))
            when.font = .uiDigits(11)
            when.textColor = .secondaryLabelColor
            end = when
        }
        for field in [name, detail, text] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let rowView = NSStackView(views: [icon, text, NSView(), end])
        rowView.spacing = 8
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return rowView
    }

    @objc private func open() {
        guard rows.indices.contains(table.clickedRow) else { return }
        let item = rows[table.clickedRow]
        // Only a web page: the record may be a cloned repository's (`Artifacts.record` refuses any other scheme too).
        if item.url != nil {
            if let url = URL(string: item.target), url.scheme == "https" { PreviewLinks.openOutside(url) }
        } else {
            app.workbench.open(item.target)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        let item = rows[table.clickedRow], app = self.app
        menu.add(String(localized: "Open")) { [weak self] in self?.open() }
        if let session = item.session.flatMap(app.session), session.status != .exited {
            menu.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: session.id) }
        }
        menu.addItem(.separator())
        if let link = item.url {
            menu.add(String(localized: "Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
        } else {
            menu.add(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.target)])
            }
        }
    }
}
