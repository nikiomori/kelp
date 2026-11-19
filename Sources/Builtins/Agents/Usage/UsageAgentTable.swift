import AppKit
import DesignKit
import SwiftUI

/// The usage report's agents as the system's table: its header sorts by a click and the other way by a second, its
/// columns take the widths they are dragged to and keep them, a row can be chosen (which narrows the page to that
/// agent) and walked with ↑ ↓, and the agents with no list price open under a disclosure triangle. The cells are the
/// report's own SwiftUI views (a chart, a share bar), which the table hosts. It stands in a page that scrolls, so it
/// is as tall as its rows and leaves the wheel to the page.
struct UsageAgentTable: NSViewRepresentable {
    enum Column: String, CaseIterable { case agent, span, share, tokens, cost }
    /// A row: an agent's line by its id, or the fold of the agents with no list price over theirs. `picks` is false
    /// for a row that narrows nothing (the fold, an agent with nothing counted).
    struct Item {
        let id: String
        var children: [Item] = []
        var picks = true
    }

    let items: [Item]
    /// The rows' cells in the columns' order, made while the report draws (its state can't be read later).
    let cells: [String: [AnyView]]
    /// Everything the cells show, in one string: the table is filled again only when it changes.
    let stamp: String
    let spanTitle: String
    @Binding var selected: String?
    @Binding var order: UsageReportView.AgentOrder

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make(self) }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.show(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let outline = context.coordinator.outline, rows = outline.numberOfRows
        let header = outline.headerView?.frame.height ?? 0
        return CGSize(width: proposal.width ?? 0, height: header + (rows > 0 ? outline.rect(ofRow: rows - 1).maxY : 0))
    }

    fileprivate func made(_ kind: Column) -> NSTableColumn {
        let column = NSTableColumn(identifier: .init(kind.rawValue))
        column.title =
            switch kind {
            case .agent: String(localized: "Agent")
            case .span: spanTitle
            case .share: String(localized: "Share of cost")
            case .tokens: String(localized: "Tokens")
            case .cost: String(localized: "At API prices")
            }
        let numeric = kind == .tokens || kind == .cost
        column.width = kind == .share ? Self.share : numeric ? Self.number : Self.wide
        column.minWidth = numeric ? Self.number - Metrics.inset * 2 : Self.narrow
        if numeric { column.headerCell.alignment = .right }
        // A name sorts from A first, a figure from the biggest: what a first click on each is after.
        if let sort = UsageReportView.AgentSort(rawValue: kind.rawValue) {
            column.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: !numeric)
        }
        return column
    }
    private static let wide: CGFloat = 170, narrow: CGFloat = 120, share: CGFloat = 190, number: CGFloat = 104

    final class Node: NSObject {
        let id: String, picks: Bool
        var children: [Node] = []
        init(_ item: Item) {
            id = item.id
            picks = item.picks
            children = item.children.map(Node.init)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let outline = NSOutlineView()
        private var table: UsageAgentTable?
        private var roots: [Node] = [], stamp: String?
        /// The fold of the agents with no list price, while someone has it open.
        private var open: Set<String> = []
        private var filling = false

        /// The outline in its scroll view, set up as the system's table and filled from `table`.
        func make(_ table: UsageAgentTable) -> NSScrollView {
            let scroll = StillScrollView()
            scroll.documentView = outline
            scroll.drawsBackground = false
            outline.backgroundColor = .clear
            outline.style = .inset
            outline.usesAlternatingRowBackgroundColors = true
            outline.rowSizeStyle = .custom
            outline.rowHeight = TextSize.of(Metrics.rowTwoLine)
            outline.indentationPerLevel = Metrics.indentStep
            outline.allowsColumnReordering = false   // the first column carries the triangle
            outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            for column in Column.allCases { outline.addTableColumn(table.made(column)) }
            outline.outlineTableColumn = outline.tableColumns.first
            outline.autosaveName = "UsageAgents"   // the widths someone dragged: a view preference of this Mac
            outline.autosaveTableColumns = true
            outline.dataSource = self
            outline.delegate = self
            outline.sortDescriptors = [
                NSSortDescriptor(key: table.order.by.rawValue, ascending: table.order.ascending)
            ]
            show(table)
            return scroll
        }

        func show(_ table: UsageAgentTable) {
            self.table = table
            outline.tableColumns.first { $0.identifier.rawValue == Column.span.rawValue }?.title = table.spanTitle
            if stamp != table.stamp {
                stamp = table.stamp
                roots = table.items.map(Node.init)
                filling = true
                outline.reloadData()
                for root in roots where open.contains(root.id) { outline.expandItem(root) }
                filling = false
            }
            // The page's choice and the table's are one: a filter cleared by Show All leaves no row chosen.
            let row = table.selected.flatMap { id in (0..<outline.numberOfRows).first { node($0)?.id == id } } ?? -1
            guard row != outline.selectedRow else { return }
            filling = true
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
            } else {
                outline.deselectAll(nil)
            }
            filling = false
        }
        private func node(_ row: Int) -> Node? { outline.item(atRow: row) as? Node }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Node)?.children.isEmpty ?? true)
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Node)?.picks ?? false
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { QuietRow() }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !filling, let table else { return }
            let chosen = node(outline.selectedRow)?.id
            if table.selected != chosen { table.selected = chosen }
        }
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let table, let first = outlineView.sortDescriptors.first,
                let sort = first.key.flatMap(UsageReportView.AgentSort.init)
            else { return }
            let asked = UsageReportView.AgentOrder(by: sort, ascending: first.ascending)
            if table.order != asked { table.order = asked }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { fold(notification, open: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { fold(notification, open: false) }
        private func fold(_ notification: Notification, open isOpen: Bool) {
            guard !filling, let node = notification.userInfo?["NSObject"] as? Node else { return }
            if isOpen { open.insert(node.id) } else { open.remove(node.id) }
            outline.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let column,
                let index = Column.allCases.firstIndex(where: { $0.rawValue == column.identifier.rawValue }),
                let views = table?.cells[node.id], views.indices.contains(index)
            else { return nil }
            if let cell = outline.makeView(withIdentifier: column.identifier, owner: nil) as? HostCell {
                cell.host.rootView = views[index]
                return cell
            }
            let cell = HostCell(views[index])
            cell.identifier = column.identifier
            return cell
        }
    }

    /// A cell that holds one of the report's SwiftUI views.
    final class HostCell: NSTableCellView {
        let host: NSHostingView<AnyView>
        init(_ view: AnyView) {
            host = NSHostingView(rootView: view)
            super.init(frame: .zero)
            pin(host)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
    }

    /// A row whose choice is drawn in the quiet grey whether or not the table has the keys. The cells are SwiftUI's,
    /// whose words don't turn white on the accent as a text field's do.
    final class QuietRow: NSTableRowView {
        override var isEmphasized: Bool {
            get { false }
            set {}
        }
    }
}
