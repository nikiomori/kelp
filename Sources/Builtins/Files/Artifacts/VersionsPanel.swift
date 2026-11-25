import AppKit
import Core
import DesignKit
import KelpKit

/// A page's versions as a column beside it (its bar's "N of M"): each one's number, who made it (you, its agent, or a
/// restore), when, and the prompt or the edits that made it, newest first, found by its words. The chosen one shows on
/// the page; Restore brings it back as a new version, so nothing is erased. A version kept by a name of the user's own
/// (`Artifacts.savedFile`) shows first, by that name, and is never let go with the oldest.
@MainActor
final class VersionsPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
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
    /// The saved versions' names, by number.
    private var saved: [Int: String] = [:]
    private var savedFile: String {
        ((bar.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(Artifacts.savedFile)
    }

    init(bar: ArtifactBar) {
        self.bar = bar
        super.init(frame: .zero)
        let head = Bar.panel([
            NSTextField.label(String(localized: "Versions"), font: .ui(TextSize.row, weight: .medium))
        ])
        search.placeholderString = String(localized: "Search Versions")
        search.target = self
        search.action = #selector(reload)
        let field = NSStackView(views: [search, subtitle])
        field.orientation = .vertical
        field.alignment = .leading
        field.spacing = Metrics.lineGap
        field.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: Metrics.gap, right: Metrics.inset)
        let column = NSTableColumn()
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
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
        widthAnchor.constraint(equalToConstant: Metrics.popoverWidth).isActive = true
        foot.heightAnchor.constraint(equalToConstant: Metrics.panelHeader).isActive = true
        table.menu = NSMenu()
        table.menu?.delegate = self
        reload()
        let app = bar.app
        Task {
            let text = await app.quiet(FilesRead(path: savedFile))?.text
            do { saved = try Artifacts.saved(text) } catch {
                Banner.show(
                    String(localized: "Kept versions’ names can’t be read: fix \(Artifacts.savedFile) or remove it."),
                    style: .error)
            }
            reload()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    @objc func reload() {
        let words = search.stringValue.trimmingCharacters(in: .whitespaces)
        let all: [(index: Int, entry: ArtifactBar.Entry)] = bar.entries.enumerated().reversed()
            .map { ($0.offset, $0.element) }.filter { row in
                words.isEmpty
                    || (row.entry.version.flatMap { saved[$0.n] } ?? row.entry.label)
                        .localizedCaseInsensitiveContains(words)
            }
        let isSaved = { (row: (index: Int, entry: ArtifactBar.Entry)) in
            row.entry.version.map { self.saved[$0.n] != nil } ?? false
        }
        rows = all.filter(isSaved) + all.filter { !isSaved($0) }
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
        restore.title = entry.map { String(localized: "Restore Version \($0.n)") } ?? String(localized: "Restore")
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
            entry.version.map { "v\($0.n)" } ?? String(localized: "Now"),
            font: .uiDigits(TextSize.row, weight: .medium))
        let who = NSTextField.label(source(entry), font: .ui(TextSize.caption), color: .secondaryLabelColor)
        who.isHidden = entry.version == nil
        let when = NSTextField.label(
            ArtifactBar.time(entry.at), font: .ui(TextSize.caption), color: .secondaryLabelColor)
        let top = NSStackView(views: [number, who, NSView(), when])
        top.spacing = Metrics.gap
        let name = entry.version.flatMap { saved[$0.n] }
        let label = NSTextField.label(
            name ?? entry.label, font: .ui(TextSize.row, weight: name == nil ? .regular : .medium),
            color: name == nil ? .secondaryLabelColor : .labelColor)
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
        if saved[version.n] != nil { return String(localized: "Kept") }
        if version.restored != nil { return String(localized: "Restored") }
        if version.byUser == true { return String(localized: "You") }
        return bar.agentName ?? String(localized: "Agent")
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !filling, let chosen else { return }
        let index = chosen.index == bar.entries.count - 1 ? nil : chosen.index
        if index != bar.shown { bar.show(index) }
        updateButtons()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow), let version = rows[table.clickedRow].entry.version else {
            return
        }
        if saved[version.n] != nil {
            menu.add(String(localized: "Stop Keeping This Version")) { [weak self] in self?.save(version.n, as: nil) }
        } else {
            menu.add(String(localized: "Keep This Version…")) { [weak self] in self?.askName(version) }
        }
    }

    private func askName(_ version: ArtifactVersion) {
        Task {
            guard
                let typed = await prompt(
                    String(localized: "Keep Version \(version.n)"),
                    String(localized: "A kept version shows by its name and isn’t removed with the oldest."),
                    initial: String(version.label.prefix(60)), action: String(localized: "Keep"))
            else { return }
            let name = typed.trimmingCharacters(in: .whitespaces)
            save(version.n, as: name.isEmpty ? "v\(version.n)" : name)
        }
    }

    private func save(_ n: Int, as name: String?) {
        var next = saved
        next[n] = name
        let app = bar.app
        Task {
            do {
                let text = try Artifacts.savedJSON(next)
                guard await app.call(FilesWrite(path: savedFile, text: text, base: nil)) != nil else { return }
                saved = next
                reload()
            } catch {
                Banner.show(error.localizedDescription, style: .error)
            }
        }
    }

    private func showChat() {
        if let id = bar.chat { bar.app.workbench.focus(session: id) }
    }

    /// Brings the chosen version back as the page, kept as a new version that says where it came from: nothing is
    /// erased, so it doesn't ask (as the bar's Restore doesn't).
    @objc private func restoreChosen() {
        guard let version = chosen?.entry.version else { return }
        Task { await bar.restore(version) }
    }
}
