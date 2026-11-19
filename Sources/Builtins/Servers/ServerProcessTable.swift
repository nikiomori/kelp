import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI

/// The processes as the system's own table, the one Activity Monitor and the Finder's list have: its header sorts by
/// a click and the other way by a second one, its columns take the widths they are dragged to and keep them, every
/// other row is shaded, a row can be chosen and walked with ↑ ↓, and a program's processes open under a disclosure
/// triangle. It is AppKit's outline view, not SwiftUI's `Table`, which took the reading every 2 s as an update in the
/// middle of its own (AppKit's "reentrant operation" warning). Here a reading changes the rows' words in place.
struct ProcessTable: NSViewRepresentable {
    static let part: CGFloat = 140, user: CGFloat = 96, number: CGFloat = 72
    /// The narrowest the table can be and keep its columns whole, with a little of the command.
    static let least: CGFloat = part + user + 3 * number + 160

    let app: AppModel, lines: [ServerProcesses.Line]
    @Binding var order: ServerProcesses.Order

    func makeCoordinator() -> Coordinator { Coordinator(app: app, order: $order) }

    func makeNSView(context: Context) -> NSScrollView {
        let rows = context.coordinator, outline = rows.outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.backgroundColor = .clear
        outline.style = .inset
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowSizeStyle = .custom
        outline.rowHeight = TextSize.of(Metrics.row)
        outline.indentationPerLevel = Metrics.indentStep
        outline.allowsColumnReordering = false   // the first column carries the triangles
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for column in Column.allCases { outline.addTableColumn(column.made) }
        outline.outlineTableColumn = outline.tableColumns.first
        // The widths someone dragged are theirs to keep: a view preference of this Mac.
        outline.autosaveName = "ServerProcesses"
        outline.autosaveTableColumns = true
        outline.dataSource = rows
        outline.delegate = rows
        outline.target = rows
        outline.doubleAction = #selector(Coordinator.opened)
        outline.onReturn = { [weak rows] in rows?.opened() }
        outline.menu = NSMenu()
        outline.menu?.delegate = rows
        outline.sortDescriptors = [order.descriptor]
        rows.show(lines)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.show(lines) }

    enum Column: String, CaseIterable {
        case command, part, user, cpu, memory, running

        @MainActor var made: NSTableColumn {
            let column = NSTableColumn(identifier: .init(rawValue))
            column.title =
                switch self {
                case .command: String(localized: "Command")
                case .part: String(localized: "Part of")
                case .user: String(localized: "User")
                case .cpu: String(localized: "CPU")
                case .memory: String(localized: "Memory")
                case .running: String(localized: "Running")
                }
            column.width = self == .part ? ProcessTable.part : self == .user ? ProcessTable.user : ProcessTable.number
            column.minWidth = self == .command ? 160 : 48
            if numeric { column.headerCell.alignment = .right }
            // A name sorts from A first, a number from the biggest: what a first click on each is after.
            if let sort { column.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: !numeric) }
            return column
        }
        var numeric: Bool { [.cpu, .memory, .running].contains(self) }
        var sort: ServerProcesses.Sort? { ServerProcesses.Sort(rawValue: rawValue) }
    }

    /// A row of the outline: a line (one process, or a program's several) or one of a folded line's processes. It is
    /// an object, and the same one from reading to reading, because the outline knows its rows by identity.
    final class Node: NSObject {
        let id: String
        var line: ServerProcesses.Line?, process: HostStats.Process
        var children: [Node] = []
        init(id: String, process: HostStats.Process) {
            self.id = id
            self.process = process
        }
        /// The folded line of several processes, or nil for a row that is one process.
        var group: ServerProcesses.Line? { (line?.members.count ?? 0) > 1 ? line : nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let outline = KeyOutline()
        private let app: AppModel
        private var order: Binding<ServerProcesses.Order>
        private var nodes: [String: Node] = [:], roots: [Node] = []
        /// The folded lines someone opened, by id. The view's own state, as the widths' are the table's.
        private var open: Set<String> = []
        private var reloading = false

        init(app: AppModel, order: Binding<ServerProcesses.Order>) {
            self.app = app
            self.order = order
        }

        func show(_ lines: [ServerProcesses.Line]) {
            // A row's shape: its id, whether it folds (a line that grew a second process gains its triangle), and its
            // children while open.
            func shape() -> [[String]] {
                roots.map {
                    [$0.id, $0.children.isEmpty ? "" : "+"] + (open.contains($0.id) ? $0.children.map(\.id) : [])
                }
            }
            let before = shape()
            var kept: [String: Node] = [:]
            func node(_ id: String, _ process: HostStats.Process) -> Node {
                let node = nodes[id] ?? Node(id: id, process: process)
                node.process = process
                kept[id] = node
                return node
            }
            roots = lines.map { line in
                let root = node(line.id, line.members[0])
                root.line = line
                root.children =
                    line.members.count > 1 ? line.members.map { node("\(line.id)\u{1F}\($0.pid)", $0) } : []
                return root
            }
            nodes = kept
            open.formIntersection(kept.keys)
            let after = shape()
            guard before != after else {
                // The same rows in the same order: only their figures moved, so they are written in place.
                let all = IndexSet(0..<outline.numberOfRows), columns = IndexSet(0..<outline.numberOfColumns)
                return outline.reloadData(forRowIndexes: all, columnIndexes: columns)
            }
            let chosen = (outline.item(atRow: outline.selectedRow) as? Node)?.id
            reloading = true
            outline.reloadData()
            for root in roots where open.contains(root.id) { outline.expandItem(root) }
            reloading = false
            let row = chosen.flatMap { nodes[$0] }.map { outline.row(forItem: $0) } ?? -1
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }

        /// A double click or Return: a process of an agent shows that agent, a folded line opens or folds.
        @objc func opened() {
            guard let node = outline.item(atRow: outline.actedRow) as? Node else { return }
            if node.group != nil {
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else if let session = node.process.session {
                app.workbench.focus(session: session)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Node)?.children.isEmpty ?? true)
        }
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let first = outlineView.sortDescriptors.first, let sort = first.key.flatMap(ServerProcesses.Sort.init)
            else { return }
            let asked = ServerProcesses.Order(by: sort, ascending: first.ascending)
            if asked != order.wrappedValue { order.wrappedValue = asked }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { fold(notification, open: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { fold(notification, open: false) }
        private func fold(_ notification: Notification, open isOpen: Bool) {
            guard !reloading, let node = notification.userInfo?["NSObject"] as? Node else { return }
            if isOpen { open.insert(node.id) } else { open.remove(node.id) }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let column, let kind = Column(rawValue: column.identifier.rawValue) else {
                return nil
            }
            let process = node.process, group = node.group
            switch kind {
            case .command:
                let cell = outline.reused(column, CommandCell.self)
                let tail =
                    group.map { String(localized: "\($0.members.count) processes") }
                    ?? ServerReading.arguments(process)
                cell.show(process.command, pid: group == nil ? "\(process.pid)" : "", tail: tail)
                cell.toolTip = group == nil ? process.args : nil
                return cell
            case .part:
                let cell = outline.reused(column, PartCell.self)
                cell.show(process, app: app)
                return cell
            case .user: return text(column, group?.users ?? process.user, .secondaryLabelColor)
            case .cpu: return text(column, ServerReading.percent(group?.cpu ?? process.cpu), .labelColor)
            case .memory:
                let memory = group?.memory ?? process.memory
                return text(column, memory > 0 ? bytes(memory) : "–", .labelColor)
            case .running:
                let seconds = Double(group?.seconds ?? process.seconds)
                return text(column, shortSpan(seconds, units: 2, smallest: .second), .secondaryLabelColor)
            }
        }
        private func text(_ column: NSTableColumn, _ words: String, _ color: NSColor) -> NSView {
            let cell = outline.reused(column, TextCell.self)
            cell.label.stringValue = words
            cell.label.textColor = color
            cell.label.alignment = Column(rawValue: column.identifier.rawValue)?.numeric == true ? .right : .left
            return cell
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let node = outline.item(atRow: outline.clickedRow) as? Node, node.group == nil else { return }
            let process = node.process, app = app
            if let session = process.session {
                menu.add(String(localized: "Show Agent")) { app.workbench.focus(session: session) }
            }
            menu.add(String(localized: "Copy Command Line")) { copyText(process.args) }
            menu.add(String(localized: "Copy PID")) { copyText("\(process.pid)") }
        }
    }
}

/// The outline with Return for a row's own action, as `KeyTable` gives a list.
final class KeyOutline: NSOutlineView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), let onReturn { onReturn() } else { super.keyDown(with: event) }
    }
    /// A cell of `kind` for `column`: one the outline set aside, or a new one.
    func reused<Cell: NSTableCellView>(_ column: NSTableColumn, _ kind: Cell.Type) -> Cell {
        if let cell = makeView(withIdentifier: column.identifier, owner: nil) as? Cell { return cell }
        let cell = Cell()
        cell.identifier = column.identifier
        return cell
    }
}

/// One line of text in a column. It is the cell's `textField`, so the system writes it white on a chosen row.
final class TextCell: NSTableCellView {
    let label = NSTextField.label("", font: .uiDigits(TextSize.row))
    override init(frame: NSRect) {
        super.init(frame: frame)
        textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// A process's name, then its pid and what follows the program on its command line, both in grey. The three are the
/// cell's own subviews, so each follows the row's selection.
final class CommandCell: NSTableCellView {
    private let name = NSTextField.label("", font: .ui(TextSize.row))
    private let pid = NSTextField.label("", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor)
    private let tail = NSTextField.label("", font: .ui(TextSize.row), color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField = name
        for field in [name, pid, tail] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            field.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        // The name stays whole and the pid with it; the arguments are what gives way.
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pid.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            pid.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: Metrics.gap),
            tail.leadingAnchor.constraint(equalTo: pid.trailingAnchor, constant: Metrics.gap),
            tail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ command: String, pid number: String, tail words: String) {
        name.stringValue = command
        pid.stringValue = number
        tail.stringValue = words
    }
}

/// What a process is part of: its Kelp agent with its status, its container or its systemd unit.
final class PartCell: NSTableCellView {
    private static let markSide: CGFloat = 12   // a chat's mark in a row
    private let label = NSTextField.label("", font: .ui(TextSize.row))
    private let symbol = NSImageView()
    /// The agent's mark and whose it is. It is kept from reading to reading, so its arc turns on without a start.
    private var mark: (session: String, view: NSHostingView<StatusIcon>)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField = label
        imageView = symbol
        symbol.symbolConfiguration = .chrome(Metrics.iconSmall)
        symbol.contentTintColor = .secondaryLabelColor
        for view in [symbol, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.widthAnchor.constraint(equalToConstant: Metrics.appIcon),
            label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: Metrics.lineGap * 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ process: HostStats.Process, app: AppModel) {
        let session = process.session.flatMap(app.session)
        if mark?.session != session?.id {
            mark?.view.removeFromSuperview()
            mark = nil
        }
        symbol.image = nil
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        toolTip = nil
        if let session {
            show(StatusIcon(status: session.markStatus, of: session), for: session.id)
            label.stringValue = app.catalog.displayName(session)
            label.textColor = .labelColor
        } else if process.session != nil {
            label.stringValue = String(localized: "Kelp")
        } else if let place = ServerReading.place(process) {
            symbol.image = .symbol(place.symbol)
            label.stringValue = place.name
            label.lineBreakMode = .byTruncatingMiddle
            toolTip = process.container.map { String(localized: "Container \($0)") } ?? process.unit
        } else {
            label.stringValue = ""
        }
    }

    /// The agent's own mark where the symbol stands, drawn as everywhere a chat stands.
    private func show(_ icon: StatusIcon, for session: String) {
        if let mark { return mark.view.rootView = icon }
        let view = NSHostingView(rootView: icon)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: symbol.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: Self.markSide),
            view.heightAnchor.constraint(equalToConstant: Self.markSide)
        ])
        mark = (session, view)
    }
}
