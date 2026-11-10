import AppKit
import Core
import DesignKit
import KelpKit

/// Open Database (⌃⌘K), as TablePlus' ⌘K: a few letters find a database of the project or of All My Projects; after a
/// "/" ("agro/crops") they find a table of the one before it. Return opens it, Escape goes.
@MainActor
final class DatabaseOpener: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Item {
        case database(DatabaseInfo), table(database: String, DatabaseSchema.Table)
    }
    private let app: AppModel, worktreeId: String
    private let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
    private let field = NSSearchField()
    private let list = NSTableView()
    private var items: [Item] = []
    /// The tables of the database named before the "/", once read.
    private var tables: (database: String, tables: [DatabaseSchema.Table])?

    static func run(_ app: AppModel, worktreeId: String) async {
        let opener = DatabaseOpener(app: app, worktreeId: worktreeId)
        _ = await runSheet(opener.window)
    }

    private init(app: AppModel, worktreeId: String) {
        self.app = app
        self.worktreeId = worktreeId
        super.init()
        field.placeholderString = String(localized: "Database, or database/table")
        field.delegate = self
        field.controlSize = .large
        let scroll = list.plainList("o")
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(open)
        list.rowHeight = TextSize.of(Metrics.rowTwoLine)
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        let hint = NSTextField(
            labelWithString: String(localized: "↩ opens · / goes into a database's tables · ⎋ closes"))
        hint.font = .ui(TextSize.caption)
        hint.textColor = .tertiaryLabelColor
        window.contentView = SheetForm.stack([field, scroll, hint], wide: [field, scroll], width: 460)
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        window.initialFirstResponder = field
        filter()
    }

    private var everything: [DatabaseInfo] {
        let event = app.latest(DatabasesEvent.self, worktreeId)
        return (event?.databases ?? []) + (event?.library ?? [])
    }

    private func filter() {
        let text = field.stringValue.lowercased()
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, let db = everything.first(where: { $0.name.lowercased().hasPrefix(parts[0]) }) {
            if tables?.database != db.name { load(db.name) }
            let found = (tables?.database == db.name ? tables?.tables ?? [] : []).filter {
                parts[1].isEmpty || $0.name.lowercased().contains(parts[1])
            }
            items = found.prefix(200).map { .table(database: db.name, $0) }
        } else {
            items = everything.filter {
                text.isEmpty || [$0.name, $0.address, $0.group ?? ""].joined(separator: " ").lowercased().contains(text)
            }.map(Item.database)
        }
        list.reloadData()
        if !items.isEmpty { list.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private func load(_ name: String) {
        tables = (name, [])
        Task {
            let schema = await app.quiet(DatabaseSchemaRead(worktreeId: worktreeId, database: name))
            guard tables?.database == name else { return }
            tables = (name, schema?.tables ?? [])
            filter()
        }
    }

    func controlTextDidChange(_ n: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): open()
        case #selector(NSResponder.cancelOperation(_:)): window.sheetParent?.endSheet(window, returnCode: .cancel)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let down = selector == #selector(NSResponder.moveDown(_:))
            let next = max(0, min(items.count - 1, list.selectedRow + (down ? 1 : -1)))
            list.selectRowIndexes([next], byExtendingSelection: false)
            list.scrollRowToVisible(next)
        default: return false
        }
        return true
    }

    @objc private func open() {
        let row = list.selectedRow >= 0 ? list.selectedRow : list.clickedRow
        guard items.indices.contains(row) else { return NSSound.beep() }
        let uri =
            switch items[row] {
            case .database(let db): DatabaseURI(worktree: worktreeId, name: db.name).uri
            case .table(let db, let table): DatabaseURI(worktree: worktreeId, name: db, table: table.name).uri
            }
        window.sheetParent?.endSheet(window, returnCode: .OK)
        app.workbench.open(uri)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let name: NSTextField, detail: NSTextField
        var views: [NSView]
        switch items[row] {
        case .database(let db):
            name = NSTextField(labelWithString: db.name)
            name.font = .ui(TextSize.body)
            detail = NSTextField(labelWithString: DatabasePanelRows.place(db) ?? db.engine.displayName)
            views = [NSImageView(image: DatabaseLook.badge(db.engine, size: 18))]
            views.append(stacked([name, detail]))
            views += [NSView()] + [DatabaseLook.stageChip(db)].compactMap { $0 }
        case .table(let db, let table):
            name = NSTextField(labelWithString: table.name)
            name.font = .uiMono(TextSize.row)
            detail = NSTextField(
                labelWithString: [db, table.rows.map { String(localized: "\($0) rows") }].compactMap { $0 }
                    .joined(separator: " · "))
            let icon = NSImageView(image: .symbol("tablecells"))
            icon.contentTintColor = .secondaryLabelColor
            views = [icon, stacked([name, detail]), NSView()]
        }
        detail.font = .ui(TextSize.caption)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        let line = NSStackView(views: views)
        line.spacing = Metrics.gapWide
        line.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gapWide, bottom: 0, right: Metrics.gapWide)
        return line
    }

    private func stacked(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineGap
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }
}
