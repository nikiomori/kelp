import AppKit
import Core
import DesignKit
import KelpKit

/// A page's versions as a column beside it (its bar's "N of M"): each one's number, who made it (you, its agent, or a
/// restore), when, and the prompt or the edits that made it, newest first, found by its words. The chosen one shows on
/// the page; Restore asks, then brings it back as a new version, so nothing is erased.
@MainActor
final class VersionsPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let bar: ArtifactBar
    private let table = NSTableView()
    private let search = NSSearchField()
    private let subtitle = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private lazy var chat = TextButton(String(localized: "Show Chat")) { [weak self] in self?.showChat() }
    private lazy var restore = NSButton(title: "", target: self, action: #selector(restoreChosen))
    /// The entries shown, newest first, with their places in the bar's list.
    private var rows: [(index: Int, entry: ArtifactBar.Entry)] = []
    /// While the list is filled: its selection then follows the bar, not the other way round.
    private var filling = false

    init(bar: ArtifactBar) {
        self.bar = bar
        super.init(frame: .zero)
        let title = NSTextField.label(String(localized: "Versions"), font: .ui(TextSize.heading, weight: .semibold))
        let head = NSStackView(views: [title, subtitle])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 0
        head.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        search.placeholderString = String(localized: "Search Prompts")
        search.target = self
        search.action = #selector(reload)
        let field = NSStackView(views: [search])
        field.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        let column = NSTableColumn()
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Metrics.rowTwoLine
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        restore.keyEquivalent = "\r"
        restore.controlSize = .small
        let foot = Bar.panel([], [chat, restore])
        let body = stacked(head, field, scroll)
        let all = stacked(body, foot)
        pin(all)
        widthAnchor.constraint(equalToConstant: 300).isActive = true
        foot.heightAnchor.constraint(equalToConstant: Metrics.panelHeader).isActive = true
        reload()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    @objc func reload() {
        let words = search.stringValue.trimmingCharacters(in: .whitespaces)
        rows = bar.entries.enumerated().reversed().map { ($0.offset, $0.element) }.filter {
            words.isEmpty || $0.entry.label.localizedCaseInsensitiveContains(words)
        }
        let kept = bar.entries.filter { $0.version != nil }.count
        subtitle.stringValue = String(
            localized: "\(kept) versions · Kelp keeps the last \(Artifacts.keptVersions) turns")
        filling = true
        defer { filling = false }
        table.reloadData()
        let shown = bar.shown ?? bar.entries.count - 1
        if let row = rows.firstIndex(where: { $0.index == shown }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateButtons()
    }

    private func updateButtons() {
        let entry = chosen?.entry.version
        restore.title = entry.map { String(localized: "Restore v\($0.n)…") } ?? String(localized: "Restore…")
        restore.isEnabled = entry != nil && chosen?.index != bar.entries.count - 1
        chat.isHidden = bar.chat == nil
    }

    private var chosen: (index: Int, entry: ArtifactBar.Entry)? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? { tableView.listRowView() }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let (index, entry) = rows[row]
        let number = NSTextField.label(
            entry.version.map { "v\($0.n)" } ?? String(localized: "Now"), font: .ui(TextSize.row, weight: .semibold))
        let who = NSTextField.label(source(entry), font: .ui(TextSize.micro), color: .secondaryLabelColor)
        who.isHidden = entry.version == nil
        who.wantsLayer = true
        who.layer?.backgroundColor = NSColor.fillRest.cgColor
        who.layer?.cornerRadius = Metrics.radiusXS
        let when = NSTextField.label(
            ArtifactBar.time(entry.at), font: .ui(TextSize.caption), color: .secondaryLabelColor)
        let top = NSStackView(views: [number, who, NSView(), when])
        top.spacing = Metrics.gap
        let label = NSTextField.label(entry.label, font: .ui(TextSize.row), color: .secondaryLabelColor)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSStackView(views: [top, label])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 0
        cell.edgeInsets = NSEdgeInsets(
            top: Metrics.gapTight, left: Metrics.inset, bottom: Metrics.gapTight, right: Metrics.inset)
        top.widthAnchor.constraint(equalTo: cell.widthAnchor, constant: -2 * Metrics.inset).isActive = true
        cell.toolTip = index == bar.entries.count - 1 ? String(localized: "The page as it is now") : entry.label
        return cell
    }

    /// Who made a version: the user by hand, a restore, or the page's agent.
    private func source(_ entry: ArtifactBar.Entry) -> String {
        guard let version = entry.version else { return "" }
        if version.restored != nil { return " " + String(localized: "Restored") + " " }
        if version.byUser == true { return " " + String(localized: "You") + " " }
        return " " + (bar.agentName ?? String(localized: "Agent")) + " "
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !filling, let chosen else { return }
        let index = chosen.index == bar.entries.count - 1 ? nil : chosen.index
        if index != bar.shown { bar.show(index) }
        updateButtons()
    }

    private func showChat() {
        if let id = bar.chat { bar.app.workbench.focus(session: id) }
    }

    /// Asks, then brings the chosen version back as the page, kept as a new version that says where it came from.
    @objc private func restoreChosen() {
        guard let version = chosen?.entry.version else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Restore version \(version.n)?")
            alert.informativeText = String(
                localized: "The page becomes version \(version.n) again, kept as a new version: nothing is erased.")
            alert.addButton(withTitle: String(localized: "Restore"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            await bar.restore(version)
        }
    }
}
