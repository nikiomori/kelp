import AppKit
import Core
import DesignKit
import KelpKit

/// The pages agents made in the workspace on screen (`.kelp/artifacts`, read by the daemon while the panel shows),
/// newest first: what each is, who made it, how far a review is answered. A file opens in a tab; a page on an agent's
/// own service in the user's browser, which is signed in to it (Kelp's tabs aren't).
@MainActor
final class ArtifactsPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let symbols = ["doc": "doc.text", "review": "checklist", "slides": "play.rectangle", "design": "square.grid.2x2",
                                  "dashboard": "chart.bar"]
    private let app: AppModel
    private let table = NSTableView()
    private let empty = EmptyStateView()
    private var rows: [ArtifactItem] = []
    private lazy var watched = Watched(.artifacts, in: app)
    private var shown = false

    init(app: AppModel) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("a")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(open)
        table.menu = NSMenu(); table.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // No bar of its own: the inspector's title names it, and there's nothing to do over the list.
        let v = NSView()
        v.pin(scroll)
        empty.place(in: v)
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The workspace on screen, its pages, and its chats: who made each page, and whether it's still writing.
        track(owner: self) { [app] in app.workbench.workspaceId } changed: { [weak self] _ in self?.watchShown() }
        track(owner: self) { [app] in app.artifacts[app.workbench.workspaceId ?? ""] } changed: { [weak self] _ in self?.reload() }
        track(owner: self) { [app] in app.sessions.map { "\($0.id)\($0.status)" } } changed: { [weak self] _ in self?.reload() }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        shown = true; watchShown()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        shown = false; watchShown()
    }
    private func watchShown() { watched.key = shown ? app.workbench.workspaceId : nil; reload() }

    private func reload() {
        let list = app.artifacts[app.workbench.workspaceId ?? ""]
        rows = list ?? []
        empty.show(list != nil && rows.isEmpty ? String(localized: "No pages yet") : nil, symbol: "doc.richtext",
                   text: String(localized: "Docs and reviews agents make for you list here. Ask for one with Make, on the start page or in +."))
        table.reloadData()
    }

    /// Saved in the last two minutes while its chat works: the agent is writing it.
    private func writing(_ r: ArtifactItem) -> Bool {
        guard let m = r.modified, app.session(r.session ?? "")?.status == .working else { return false }
        return Date().timeIntervalSince1970 - m < 120
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row], s = r.session.flatMap(app.session)
        let symbol = Self.symbols[r.type] ?? "link"
        let icon = NSImageView(image: .symbol(symbol))
        icon.symbolConfiguration = .init(pointSize: Metrics.iconPoint, weight: Metrics.iconWeight)
        icon.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: r.title)
        name.font = .ui(12, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let progress = r.points.flatMap { n in n == 0 ? nil : String(localized: "\(r.answered ?? 0) of \(n) answered") }
        var about = [s.map { app.catalog.name($0.agent) }, s?.status == .exited ? String(localized: "ended") : nil, progress]
        if let u = r.url { about.append(URL(string: u)?.host) }
        let detail = NSTextField(labelWithString: about.compactMap { $0 }.joined(separator: " · "))
        detail.font = .ui(11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = detail.stringValue.isEmpty   // the name alone, in the middle of the row
        let text = NSStackView(views: [name, detail])
        text.detachesHiddenViews = true
        text.orientation = .vertical; text.alignment = .leading
        text.spacing = Metrics.lineGap
        let end: NSView
        if writing(r) {
            let ring = NSProgressIndicator()
            ring.style = .spinning; ring.controlSize = .small
            ring.startAnimation(nil)
            ring.toolTip = String(localized: "The agent is writing it")
            end = ring
        } else {
            let when = NSTextField(labelWithString: shortAgo(Date(timeIntervalSince1970: r.created)))
            when.font = .uiDigits(11); when.textColor = .secondaryLabelColor
            end = when
        }
        for x in [name, detail, text] { x.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let rowView = NSStackView(views: [icon, text, NSView(), end]); rowView.spacing = 8
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return rowView
    }

    @objc private func open() {
        guard rows.indices.contains(table.clickedRow) else { return }
        let r = rows[table.clickedRow]
        // Only a web page: the record may be a cloned repository's (`Artifacts.record` refuses any other scheme too).
        if r.url != nil {
            if let u = URL(string: r.target), u.scheme == "https" { NSWorkspace.shared.open(u) }
        } else { app.workbench.open(r.target) }
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        let r = rows[table.clickedRow], app = self.app
        m.add(String(localized: "Open")) { [weak self] in self?.open() }
        if let s = r.session.flatMap(app.session), s.status != .exited {
            m.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: s.id) }
        }
        m.addItem(.separator())
        if let u = r.url {
            m.add(String(localized: "Copy Link")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) }
        } else {
            m.add(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.target)]) }
        }
    }
}
