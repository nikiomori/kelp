import AppKit
import Core
import DesignKit
import KelpKit

/// The column of lists on the left of the Tasks tab, as Artifacts Overview's column is: Inbox, Now, Waiting for You,
/// All and the Logbook, then each project with tasks and each tag. A row says how many it holds; Waiting for You says
/// it in orange.
@MainActor
final class TaskSourceList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        case heading(String)
        case source(TaskSource)
        var source: TaskSource? { if case .source(let s) = self { s } else { nil } }
    }

    let table = KeyTable()
    private let model: TasksModel
    private(set) var rows: [Row] = []
    private var counts: [TaskSource: Int] = [:]

    init(model: TasksModel) {
        self.model = model
        super.init()
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Lists"))
    }

    static let fixed: [TaskSource] = [.inbox, .now, .waiting, .all, .journal]

    func show(_ tasks: [TaskRow]) {
        let projects = Self.byCount(tasks.filter { TaskSource.all.holds($0) }.map(\.repo))
        let tags = TaskViews.tags(tasks)
        var next = Self.fixed.map(Row.source)
        if !projects.isEmpty {
            next += [.heading(String(localized: "Projects"))] + projects.map { .source(.project($0)) }
        }
        if !tags.isEmpty { next += [.heading(String(localized: "Tags"))] + tags.map { .source(.tag($0)) } }
        counts = TaskViews.counts(tasks, next.compactMap(\.source))
        rows = next
        table.reloadData()
        if let at = rows.firstIndex(of: .source(model.source)) {
            if table.selectedRow != at { table.selectRowIndexes([at], byExtendingSelection: false) }
        } else {
            table.deselectAll(nil)
        }
    }

    private static func byCount(_ keys: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let heading = rows[row].source == nil
        return ListRowView(lights: { _ in !heading })
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].source != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        TextSize.of(rows[row].source == nil ? Metrics.rowSection : Metrics.row)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow), let source = rows[table.selectedRow].source,
            source != model.source
        else { return }
        model.source = source
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let text): return SectionHeading(text)
        case .source(let source): return cell(source)
        }
    }

    private func cell(_ source: TaskSource) -> NSView {
        let name = NSTextField.label(title(source), font: .ui(TextSize.row))
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = counts[source] ?? 0, waits = source == .waiting && count > 0
        let number = NSTextField.label(
            count > 0 && source != .journal ? "\(count)" : "",
            font: .uiDigits(TextSize.caption, weight: waits ? .semibold : .regular),
            color: waits ? .textOrange : .secondaryLabelColor)
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        let icon = NSImageView()
        if case .project(let repo) = source, let path = model.app.repo(repo)?.path {
            ProjectIcon.show(path, in: icon, app: model.app)
        } else {
            icon.image = .symbol(symbol(source))
            icon.symbolConfiguration = .chrome()
            icon.contentTintColor = .secondaryLabelColor
        }
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let row = NSStackView(views: [icon, name, NSView(), number])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(count > 0 ? "\(title(source)), \(count)" : title(source))
        return row
    }

    func title(_ source: TaskSource) -> String {
        switch source {
        case .inbox: String(localized: "Inbox")
        case .now: String(localized: "Now")
        case .waiting: String(localized: "Waiting for You")
        case .all: String(localized: "All")
        case .journal: String(localized: "Logbook")
        case .project(let repo): model.projectName(repo)
        case .tag(let tag): tag
        }
    }
    /// The same symbols Artifacts Overview gives the same lists (Now, Waiting for You).
    private func symbol(_ source: TaskSource) -> String {
        switch source {
        case .inbox: "tray"
        case .now: "bolt"
        case .waiting: "checklist"
        case .all: "list.bullet"
        case .journal: "book.closed"
        case .project: "folder"
        case .tag: "number"
        }
    }
}

/// The rows of the chosen list, under their headings: a click chooses a row, a double click or Return shows its
/// line on its page (or the page it grew into), ⌘Return ticks it, ⇧Return hands it to the last agent, and a right
/// click shows its menu.
@MainActor
final class TaskRows: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Row {
        case heading(String, Int)
        case task(TaskRow)
    }
    let table = KeyTable()
    let scroll = NSScrollView()
    private let model: TasksModel
    private(set) var rows: [Row] = []

    init(model: TasksModel) {
        self.model = model
        super.init()
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Tasks"))
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.doubleAction = #selector(doubleClicked)
        table.allowsMultipleSelection = true   // ⌘/⇧-click: several lines, to group (⌥⌘G), close or cancel at once
        table.target = self
        // Return shows the line, ⌘Return ticks it, ⇧Return hands it to the last agent.
        table.onReturn = { [weak self] in
            guard let self, let row = chosen else { return }
            let flags = table.returnModifiers
            if flags == .command {
                TaskActions.toggle(model.app, row)
            } else if flags == .shift {
                TaskActions.run(model.app, row)
            } else {
                TaskActions.open(model.app, row)
            }
        }
        _ = table.plainList("t", in: scroll)
    }

    static func day(_ time: Double) -> String { DaySections.title(time, now: Date()) }

    func show(_ sections: [(title: String, rows: [TaskRow])]) {
        let chosen = self.chosen?.id
        rows = sections.flatMap { s in [Row.heading(s.title, s.rows.count)] + s.rows.map(Row.task) }
        table.reloadData()
        if let chosen, let at = rows.firstIndex(where: { if case .task(let r) = $0 { r.id == chosen } else { false } })
        {
            table.selectRowIndexes([at], byExtendingSelection: false)
        }
    }

    var chosen: TaskRow? { task(at: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) }
    /// The chosen lines, in the list's order.
    var selected: [TaskRow] { table.selectedRowIndexes.compactMap(task(at:)) }
    private func task(at index: Int) -> TaskRow? {
        guard rows.indices.contains(index), case .task(let row) = rows[index] else { return nil }
        return row
    }

    @objc private func doubleClicked() { task(at: table.clickedRow).map { TaskActions.open(model.app, $0) } }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = task(at: table.clickedRow) else { return }
        let many = selected
        guard many.count > 1, table.selectedRowIndexes.contains(table.clickedRow) else {
            return TaskActions.fill(menu, model.app, row)
        }
        // Several chosen: what is done to all of them at once. Handing them to an agent at once isn't offered (it
        // would be a queue): group them into one task first.
        let app = model.app
        menu.add(String(localized: "Make One Task of \(many.count)"), key: "g") { TaskActions.group(app, many) }
            .keyEquivalentModifierMask = [.option, .command]
        menu.addItem(.separator())
        menu.add(String(localized: "Mark \(many.count) as Done")) { for r in many { TaskActions.set(app, r, .done) } }
        menu.add(String(localized: "Cancel \(many.count) Tasks")) {
            for r in many { TaskActions.set(app, r, .cancelled) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .heading = rows[row] { return ListRowView(lights: { _ in false }) }
        return ListRowView()
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { task(at: row) != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .heading = rows[row] { return TextSize.of(Metrics.rowSection) }
        return TextSize.of(Metrics.rowTwoLine)
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let title, let count): return SectionHeading(title, count: count)
        case .task(let task): return cell(task)
        }
    }

    private func cell(_ row: TaskRow) -> NSView {
        var place = [model.projectName(row.repo) + " › " + row.place]
        if let ref = row.task.issueRef { place.append(ref) }
        return TaskCell(model.app, row, place: place.joined(separator: " · "))
    }
}
