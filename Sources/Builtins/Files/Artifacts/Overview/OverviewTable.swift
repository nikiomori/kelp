import AppKit
import Core
import DesignKit
import KelpKit

/// Artifacts Overview's pages as the system's table: name, kind, project and when each changed. A click on a heading
/// sorts by it, a second turns the order round; columns keep the widths dragged. Return opens the chosen page, Space
/// shows it in Quick Look, and a right click shows its menu. Rows come in the sources' order (newest first) until a
/// heading is clicked.
@MainActor
final class OverviewTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Column: String, CaseIterable {
        case name, kind, project, changed
    }

    let table = KeyTable()
    let scroll = NSScrollView()
    private let model: OverviewModel
    private(set) var pages: [OverviewPage] = []
    private var given: [OverviewPage] = []
    var onOpen: (OverviewPage) -> Void = { _ in }
    var menuFor: (OverviewPage, NSMenu) -> Void = { _, _ in }

    init(model: OverviewModel) {
        self.model = model
        super.init()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .custom
        table.rowHeight = TextSize.of(Metrics.row)
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for column in Column.allCases { table.addTableColumn(made(column)) }
        table.autosaveName = "ArtifactsOverview"   // the widths someone dragged: a view preference of this Mac
        table.autosaveTableColumns = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(opened)
        table.onReturn = { [weak self] in self?.opened() }
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setAccessibilityLabel(String(localized: "Pages"))
    }

    private func made(_ column: Column) -> NSTableColumn {
        let made = NSTableColumn(identifier: .init(column.rawValue))
        made.title =
            switch column {
            case .name: String(localized: "Name")
            case .kind: String(localized: "Kind")
            case .project: String(localized: "Project")
            case .changed: String(localized: "Changed")
            }
        made.width = column == .name ? 360 : 130
        made.minWidth = column == .name ? 160 : 70
        // A name sorts from A first, a time from the newest: what a first click on each is after.
        made.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column != .changed)
        return made
    }

    func show(_ pages: [OverviewPage]) {
        let chosen = selected?.id
        given = pages
        sort()
        if let chosen, let row = self.pages.firstIndex(where: { $0.id == chosen }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    var selected: OverviewPage? { pages.indices.contains(table.selectedRow) ? pages[table.selectedRow] : nil }

    private func sort() {
        guard let by = table.sortDescriptors.first, let key = by.key, let column = Column(rawValue: key) else {
            pages = given
            return table.reloadData()
        }
        let model = self.model
        let value: (OverviewPage) -> String = {
            switch column {
            case .name: model.title($0)
            case .kind: Artifacts.Kind(rawValue: $0.item.type).map(ArtifactStart.title) ?? $0.item.type
            case .project: model.projectName($0.repo)
            case .changed: String(format: "%020.3f", $0.time)
            }
        }
        // A stable sort: pages equal by the column keep the sources' order.
        pages = given.enumerated().sorted { a, b in
            let order = value(a.element).localizedStandardCompare(value(b.element))
            if order == .orderedSame { return a.offset < b.offset }
            return (order == .orderedAscending) == by.ascending
        }.map(\.element)
        table.reloadData()
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { sort() }

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let column = Column(rawValue: id) else { return nil }
        let page = pages[row], item = page.item, app = model.app
        switch column {
        case .name:
            let icon = NSImageView(image: .symbol(ArtifactCells.symbol(item.type)))
            icon.symbolConfiguration = .chrome()
            icon.contentTintColor = .secondaryLabelColor
            let weight: NSFont.Weight = ArtifactSeen.isNew(item, app) ? .semibold : .regular
            let name = NSTextField.label(model.title(page), font: .ui(TextSize.row, weight: weight))
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var views: [NSView] = [icon, name]
            if item.url != nil, let logo = app.catalog.icon(Session.claudeAgent, size: Metrics.iconSmall) {
                let mark = NSImageView(image: logo)
                mark.toolTip = String(localized: "On claude.ai: opens in your browser")
                views.append(mark)
            }
            if let note = ArtifactActions.note(item, app) {
                views.append(
                    NSTextField.label(
                        note.text, font: .ui(TextSize.caption), color: note.waits ? .textOrange : .secondaryLabelColor))
            }
            let cell = NSStackView(views: views)
            cell.spacing = Metrics.gap
            cell.toolTip = item.title
            return cell
        case .kind, .project, .changed:
            let text: String =
                switch column {
                case .kind: Artifacts.Kind(rawValue: item.type).map(ArtifactStart.title) ?? String(localized: "Page")
                case .project: model.projectName(page.repo)
                default:
                    Date(timeIntervalSince1970: page.time).formatted(date: .abbreviated, time: .shortened)
                }
            let label = NSTextField.label(
                text, font: column == .changed ? .uiDigits(TextSize.row) : .ui(TextSize.row),
                color: .secondaryLabelColor)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return NSStackView(views: [label])   // centred in the row, as the name beside it
        }
    }

    @objc private func opened() {
        let row = table.actedRow
        guard pages.indices.contains(row) else { return }
        onOpen(pages[row])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard pages.indices.contains(table.clickedRow) else { return }
        menuFor(pages[table.clickedRow], menu)
    }
}
