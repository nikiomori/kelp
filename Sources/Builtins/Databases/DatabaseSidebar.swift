import AppKit
import Core
import DesignKit
import KelpKit

/// The database tab's left column, like TablePlus' and TablePro's. Items lists the Functions, Views and Tables of the
/// schema picked at the column's foot; each section folds, and names are in the chrome's mono face (`.uiMono`).
/// Queries lists the saved queries and New Query, and History lists what agents and the user ran here. The search
/// finds items by name, and a table by its columns too.
@MainActor
final class DatabaseSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row {
        case section(String, count: Int, open: Bool)
        case table(DatabaseSchema.Table), function(String)
        case newQuery, saved(SavedQuery), run(DatabaseRun)
    }
    struct SavedQuery: Codable, Equatable {
        var name: String, sql: String
    }

    let view = NSView()
    private let part = CapsuleSegments(
        labels: [String(localized: "Items"), String(localized: "Queries"), String(localized: "History")],
        name: String(localized: "Show"))
    private let search = NSSearchField()
    let list = NSTableView()
    private let schemaPicker = NSPopUpButton()
    private var rows: [Row] = []
    private var folded: Set<String> = [String(localized: "Functions")]
    private let app: AppModel

    var schema = DatabaseSchema(tables: []) {
        didSet { schemasChanged() }
    }
    var runs: [DatabaseRun] = [] {
        didSet { if part.selectedSegment == 2 { reload() } }
    }
    var saved: [SavedQuery] = [] {
        didSet { if part.selectedSegment == 1 { reload() } }
    }
    /// The table on screen, which the list keeps selected.
    var current: String? {
        didSet { select() }
    }
    var onTable: (String, _ pin: Bool) -> Void = { _, _ in }
    var onNewQuery: () -> Void = {}
    var onSaved: (SavedQuery) -> Void = { _ in }
    var onForget: (SavedQuery) -> Void = { _ in }
    var onRun: (DatabaseRun, _ toEditor: Bool) -> Void = { _, _ in }
    var onUndo: (DatabaseRun) -> Void = { _ in }
    var onAsk: (String) -> Void = { _ in }
    var onCopyCreate: (String) -> Void = { _ in }

    init(app: AppModel) {
        self.app = app
        super.init()
        part.selectedSegment = 0
        part.controlSize = .small
        part.target = self
        part.action = #selector(partChanged)
        search.placeholderString = String(localized: "Search")
        search.controlSize = .small
        search.delegate = self
        let scroll = list.plainList("s")
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.action = #selector(clicked)
        list.doubleAction = #selector(doubleClicked)
        list.menu = NSMenu()
        list.menu?.delegate = self
        list.setDraggingSourceOperationMask(.copy, forLocal: false)
        schemaPicker.controlSize = .small
        schemaPicker.target = self
        schemaPicker.action = #selector(schemaPicked)
        let add = IconButton(.symbol("square.and.pencil"), tip: String(localized: "New Query")) { [weak self] in
            self?.onNewQuery()
        }
        let top = NSStackView(views: [part])
        top.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: 0, bottom: 0, right: 0)
        let find = NSStackView(views: [search, add])   // New Query sits beside the search, as the list's own "+"
        find.spacing = Metrics.gap
        find.edgeInsets = NSEdgeInsets(
            top: Metrics.gap, left: Metrics.gapWide, bottom: Metrics.gap, right: Metrics.gapWide)
        let foot = NSStackView(views: [schemaPicker, NSView()])   // shown only when the database has other schemas
        foot.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gap, bottom: 0, right: Metrics.gap)
        foot.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.statusBar + 4)).isActive = true
        foot.isHidden = true
        let column = NSStackView(views: [top, find, scroll, foot])
        column.orientation = .vertical
        column.spacing = 0
        for v in [find, scroll, foot] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        view.pin(column)
        // The column is as wide as the user drags it. The tab's split keeps that width per Mac, 280 until then.
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }

    // MARK: What it lists

    /// Lists "public" and the other schemas, read from the tables' "schema.name", with the default one first.
    private func schemasChanged() {
        let others = Set(
            schema.tables.compactMap { $0.name.contains(".") ? String($0.name.split(separator: ".")[0]) : nil })
        let picked = schemaPicker.titleOfSelectedItem
        schemaPicker.removeAllItems()
        schemaPicker.addItems(withTitles: [String(localized: "default")] + others.sorted())
        schemaPicker.isHidden = others.isEmpty
        schemaPicker.superview?.isHidden = others.isEmpty
        if let picked, schemaPicker.itemTitles.contains(picked) { schemaPicker.selectItem(withTitle: picked) }
        reload()
    }

    private var inSchema: [DatabaseSchema.Table] {
        let picked = schemaPicker.indexOfSelectedItem <= 0 ? nil : schemaPicker.titleOfSelectedItem
        return schema.tables.filter { table in
            let own = table.name.contains(".") ? String(table.name.split(separator: ".")[0]) : nil
            return own == picked
        }
    }

    func reload() {
        let find = search.stringValue.lowercased()
        func fits(_ table: DatabaseSchema.Table) -> Bool {
            find.isEmpty || table.name.lowercased().contains(find)
                || table.columns.contains { $0.name.lowercased() == find }
        }
        var out: [Row] = []
        switch part.selectedSegment {
        case 1:
            out = [.newQuery] + saved.filter { find.isEmpty || $0.name.lowercased().contains(find) }.map(Row.saved)
        case 2:
            out = runs.filter { find.isEmpty || $0.sql.lowercased().contains(find) }.map(Row.run)
        default:
            // Sorts as Finder does: "1_weather" before "10_weather".
            func ordered(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
            let functions = (schema.functions ?? []).filter { find.isEmpty || $0.lowercased().contains(find) }
                .sorted(by: ordered)
            let views = inSchema.filter { $0.kind == "view" && fits($0) }.sorted { ordered($0.name, $1.name) }
            let tables = inSchema.filter { $0.kind != "view" && fits($0) }.sorted { ordered($0.name, $1.name) }
            for (title, items) in [
                (String(localized: "Tables"), tables.map(Row.table)),
                (String(localized: "Views"), views.map(Row.table)),
                (String(localized: "Functions"), functions.map(Row.function))
            ] where !items.isEmpty {
                let open = !folded.contains(title) || !find.isEmpty
                out.append(.section(title, count: items.count, open: open))
                if open { out += items }
            }
        }
        rows = out
        list.reloadData()
        select()
    }

    private func select() {
        guard let current,
            let index = rows.firstIndex(where: {
                if case .table(let table) = $0 { table.name == current } else { false }
            })
        else { return list.deselectAll(nil) }
        list.selectRowIndexes([index], byExtendingSelection: false)
        list.scrollRowToVisible(index)
    }

    @objc private func partChanged() { reload() }
    @objc private func schemaPicked() { reload() }
    func controlTextDidChange(_ notification: Notification) { reload() }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .run, .saved: TextSize.of(Metrics.rowTwoLine)
        default: TextSize.of(Metrics.row)
        }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .section(let title, let count, let open):
            let chevron = NSImageView(image: .symbol(open ? "chevron.down" : "chevron.right"))
            chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
            chevron.contentTintColor = .secondaryLabelColor
            let capsule = CountCapsule()   // the title and capsule every list's section has, as the panel's do
            capsule.text = count.formatted()
            return line([chevron, DatabaseSheet.section(title), NSView(), capsule], inset: Metrics.inset)
        case .table(let table):
            let icon = symbol(table.kind == "view" ? "eye" : "tablecells")
            let name = NSTextField.label(
                table.name.split(separator: ".").last.map(String.init) ?? table.name, font: .uiMono(TextSize.caption))
            name.lineBreakMode = .byTruncatingMiddle   // "cadaster_lan…_2021": these names differ at their ends
            let row = line([icon, name, NSView()], inset: Metrics.inset + Metrics.indentStep)
            row.toolTip = [table.name, table.rows.map { String(localized: "\($0) rows") }, table.comment].compactMap {
                $0
            }
            .joined(separator: "\n")
            return row
        case .function(let name):
            let label = NSTextField.label(name, font: .uiMono(TextSize.caption))
            label.lineBreakMode = .byTruncatingMiddle
            return line([symbol("function"), label, NSView()], inset: Metrics.inset + Metrics.indentStep)
        case .newQuery:
            return line(
                [symbol("plus"), NSTextField.label(String(localized: "New Query"), font: .ui(TextSize.row)), NSView()],
                inset: Metrics.inset)
        case .saved(let query):
            return twoLines(symbol("doc.text"), query.name, query.sql)
        case .run(let run):
            let who = run.session.flatMap(app.session)
            let icon = NSImageView(image: who.flatMap { app.catalog.icon($0.agent, size: 14) } ?? .symbol("person"))
            icon.contentTintColor = .secondaryLabelColor
            let first = run.sql.split(whereSeparator: \.isNewline).joined(separator: " ")
            return twoLines(
                icon, first,
                [
                    who.map { app.catalog.name($0.agent) } ?? String(localized: "You"),
                    run.state == .done ? nil : shortAgo(run.at),   // a finished run's outcome ends with its time
                    DatabasePanelRows.outcome(run)
                ].compactMap { $0 }.joined(separator: " · "), mono: true)
        }
    }

    private func twoLines(_ icon: NSImageView, _ top: String, _ under: String, mono: Bool = false) -> NSView {
        let title = NSTextField.label(top, font: mono ? .uiMono(TextSize.caption) : .ui(TextSize.row))
        let detail = NSTextField.label(
            under, font: mono ? .ui(TextSize.caption) : .uiMono(TextSize.caption), color: .secondaryLabelColor)
        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Metrics.lineGap
        let row = line([icon, words, NSView()], inset: Metrics.inset)
        row.toolTip = top + "\n" + under
        return row
    }

    private func line(_ views: [NSView], inset: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: Metrics.insetTrailing)
        return stack
    }
    private func symbol(_ name: String) -> NSImageView {
        let icon = NSImageView(image: .symbol(name))
        icon.symbolConfiguration = .chrome(Metrics.iconSmall)
        icon.contentTintColor = .secondaryLabelColor
        return icon
    }

    // MARK: Clicks

    /// A click opens a table in the tab itself, in place of the one shown; a double click keeps it in a tab of its own.
    @objc private func clicked() {
        guard rows.indices.contains(list.clickedRow) else { return }
        switch rows[list.clickedRow] {
        case .section(let title, _, _):
            if folded.remove(title) == nil { folded.insert(title) }
            reload()
        case .table(let table): onTable(table.name, NSEvent.modifierFlags.contains(.command))
        case .newQuery: onNewQuery()
        case .saved(let query): onSaved(query)
        case .run(let run): onRun(run, NSEvent.modifierFlags.contains(.option))
        case .function: break
        }
    }

    @objc private func doubleClicked() {
        guard rows.indices.contains(list.clickedRow), case .table(let table) = rows[list.clickedRow] else { return }
        onTable(table.name, true)
    }

    /// A table dragged out (onto an agent's terminal, say) carries its name.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .table(let table) = rows[row] else { return nil }
        return table.name as NSString
    }
}

extension DatabaseSidebar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(list.clickedRow) else { return }
        switch rows[list.clickedRow] {
        case .table(let table):
            menu.add(String(localized: "Open")) { [weak self] in self?.onTable(table.name, false) }
            menu.add(String(localized: "Open in a Tab of Its Own")) { [weak self] in self?.onTable(table.name, true) }
            menu.add(String(localized: "Ask an Agent About \(table.name)")) { [weak self] in self?.onAsk(table.name) }
            menu.addItem(.separator())
            menu.add(String(localized: "Copy Name")) { copyText(table.name) }
            menu.add(String(localized: "Copy CREATE TABLE")) { [weak self] in self?.onCopyCreate(table.name) }
        case .saved(let query):
            menu.add(String(localized: "Open")) { [weak self] in self?.onSaved(query) }
            menu.add(String(localized: "Copy SQL")) { copyText(query.sql) }
            menu.addItem(.separator())
            menu.add(String(localized: "Forget…")) { [weak self] in
                Task {
                    guard
                        await confirm(
                            String(localized: "Forget \(query.name)?"),
                            detail: String(localized: "This can’t be undone."),
                            action: String(localized: "Forget"), destructive: true)
                    else { return }
                    self?.onForget(query)
                }
            }
        case .run(let run):
            menu.add(String(localized: "Show Rows")) { [weak self] in self?.onRun(run, false) }
            if run.session != nil, run.state == .done, (run.changed ?? 0) > 0 {   // an agent's change can be put back
                menu.add(String(localized: "Undo This Change…")) { [weak self] in self?.onUndo(run) }
            }
            menu.add(String(localized: "Put in the Editor")) { [weak self] in self?.onRun(run, true) }
            menu.add(String(localized: "Copy SQL")) { copyText(run.sql) }
        default: break
        }
    }
}
