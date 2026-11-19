import AppKit
import DesignKit
import SwiftUI

/// The usage report's models or projects as the system's table, built as the agents' table above them
/// (`UsageAgentTable`): its header sorts by a click and the other way by a second, its columns keep the widths they are
/// dragged to, and it is as tall as its rows and leaves the wheel to the page. With `selected`, a row can be chosen,
/// which narrows the page to that project, and a click on the chosen row goes back to all; without it no row is.
struct UsageGroupTable: NSViewRepresentable {
    enum Column: String, CaseIterable { case name, share, tokens, cost }

    /// The rows' names, in the order shown.
    let ids: [String]
    /// The rows' cells in the columns' order, made while the report draws.
    let cells: [String: [AnyView]]
    /// Everything the cells show, in one string: the table is filled again only when it changes.
    let stamp: String
    let nameTitle: String
    /// The name the widths someone dragged are kept under: a view preference of this Mac.
    let autosave: String
    var selected: Binding<String?>?
    @Binding var order: UsageReportView.AgentOrder

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make(self) }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.show(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let list = context.coordinator.list, rows = list.numberOfRows
        let header = list.headerView?.frame.height ?? 0
        return CGSize(width: proposal.width ?? 0, height: header + (rows > 0 ? list.rect(ofRow: rows - 1).maxY : 0))
    }

    fileprivate func made(_ kind: Column) -> NSTableColumn {
        let column = NSTableColumn(identifier: .init(kind.rawValue))
        column.title =
            switch kind {
            case .name: nameTitle
            case .share: String(localized: "Share")
            case .tokens: String(localized: "Tokens")
            case .cost: String(localized: "At API prices")
            }
        let numeric = kind == .tokens || kind == .cost
        column.width = kind == .name ? 140 : kind == .share ? 90 : kind == .tokens ? 64 : 84
        column.minWidth = kind == .name ? 60 : 44
        if numeric { column.headerCell.alignment = .right }
        // A name sorts from A first, a figure from the biggest, as in the agents' table (whose name column is `agent`).
        if let sort = kind == .name ? UsageReportView.AgentSort.agent : .init(rawValue: kind.rawValue) {
            column.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: !numeric)
        }
        return column
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let list = ToggleTable()
        private var table: UsageGroupTable?
        private var ids: [String] = [], stamp: String?
        private var filling = false

        /// The table in its scroll view, set up as the agents' table and filled from `table`.
        func make(_ table: UsageGroupTable) -> NSScrollView {
            let scroll = StillScrollView()
            scroll.documentView = list
            scroll.drawsBackground = false
            list.backgroundColor = .clear
            list.style = .inset
            list.usesAlternatingRowBackgroundColors = true
            list.rowSizeStyle = .custom
            list.rowHeight = TextSize.of(Metrics.row)
            list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            for column in Column.allCases { list.addTableColumn(table.made(column)) }
            list.autosaveName = table.autosave
            list.autosaveTableColumns = true
            list.dataSource = self
            list.delegate = self
            list.sortDescriptors = [NSSortDescriptor(key: table.order.by.rawValue, ascending: table.order.ascending)]
            show(table)
            return scroll
        }

        func show(_ table: UsageGroupTable) {
            self.table = table
            if stamp != table.stamp {
                stamp = table.stamp
                ids = table.ids
                filling = true
                list.reloadData()
                filling = false
            }
            // The page's choice and the table's are one: a project cleared elsewhere leaves no row chosen.
            let row = table.selected?.wrappedValue.flatMap { ids.firstIndex(of: $0) } ?? -1
            guard row != list.selectedRow else { return }
            filling = true
            if row >= 0 {
                list.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                list.deselectAll(nil)
            }
            filling = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { ids.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { table?.selected != nil }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            UsageAgentTable.QuietRow()
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !filling, let selected = table?.selected else { return }
            let chosen = ids.indices.contains(list.selectedRow) ? ids[list.selectedRow] : nil
            if selected.wrappedValue != chosen { selected.wrappedValue = chosen }
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let table, let first = tableView.sortDescriptors.first,
                let sort = first.key.flatMap(UsageReportView.AgentSort.init)
            else { return }
            let asked = UsageReportView.AgentOrder(by: sort, ascending: first.ascending)
            if table.order != asked { table.order = asked }
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, ids.indices.contains(row),
                let index = Column.allCases.firstIndex(where: { $0.rawValue == column.identifier.rawValue }),
                let views = table?.cells[ids[row]], views.indices.contains(index)
            else { return nil }
            if let cell = list.makeView(withIdentifier: column.identifier, owner: nil) as? UsageAgentTable.HostCell {
                cell.host.rootView = views[index]
                return cell
            }
            let cell = UsageAgentTable.HostCell(views[index])
            cell.identifier = column.identifier
            return cell
        }
    }

    /// A table whose chosen row is let go by a click on it, so a project clicked again gives back all of them.
    final class ToggleTable: NSTableView {
        override func mouseDown(with event: NSEvent) {
            let before = selectedRow
            super.mouseDown(with: event)   // tracks the click to the mouse's release
            if before >= 0, clickedRow == before { deselectAll(nil) }
        }
    }
}
