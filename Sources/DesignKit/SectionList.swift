import AppKit
import SwiftUI

/// A page's column of short lists under titles that fold, built from an inspector panel's blocks: a title in the
/// section's type with its count on a capsule, rows that light up under the pointer and take the system's selection,
/// ↑ ↓ along them and Return for a row's own action. A page hands it what to show. A row is drawn again only when its
/// words change, so a reading every two seconds leaves the row under the pointer alone.
public struct SectionList: NSViewRepresentable {
    public struct Action {
        public var title: String, tip: String?
        public var run: @MainActor () -> Void
        public init(_ title: String, tip: String? = nil, run: @escaping @MainActor () -> Void) {
            self.title = title
            self.tip = tip
            self.run = run
        }
    }

    public struct Row {
        public var id: String, title: String
        /// A short value before the name, in a column of its own: a port's number.
        public var key: String?
        /// Makes the row's mark: a symbol, a logo, a status. `iconKey` says what it shows, for a mark that changes
        /// while the row's words stay (an agent's status), so the row is drawn again then.
        public var icon: (@MainActor () -> NSView)?, iconKey: String?
        /// The second line, with `lead` before it in orange ("Asks:"). `mono` sets it as a command is written.
        public var detail: String?, lead: String?, mono = false
        /// The name is a path: cut in its middle, where both ends say something.
        public var path = false
        /// Said at the row's end in grey: what it takes, where it is.
        public var trailing: String?
        /// A worded action at the row's end. With `onHover` it stands in `trailing`'s place only under the pointer.
        public var button: Action?, onHover = false
        /// Where the row leads: a link at its end (`PointerButton.link`).
        public var link: Action?
        /// What a click does, and what Return or a double click does (the click's, when it has none of its own).
        public var click: (@MainActor () -> Void)?, open: (@MainActor () -> Void)?
        public var menu: [Action] = []
        public var tip: String?
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Section {
        public var id: String, title: String, rows: [Row]
        /// Said in the rows' place while there are none.
        public var note: String?
        public init(id: String, title: String, rows: [Row], note: String? = nil) {
            self.id = id
            self.title = title
            self.rows = rows
            self.note = note
        }
    }

    static let keyWidth: CGFloat = 40   // a port's five digits

    let sections: [Section]
    /// False for a list inside a page that scrolls: it is as tall as its rows and leaves the wheel to the page.
    let scrolls: Bool
    public init(_ sections: [Section], scrolls: Bool = true) {
        self.sections = sections
        self.scrolls = scrolls
    }

    /// A row's mark from a symbol, in the grey of a row's quiet marks.
    public static func symbol(_ name: String) -> @MainActor () -> NSView {
        {
            let view = NSImageView(image: .symbol(name, size: Metrics.iconSmall))
            view.symbolConfiguration = .chrome(Metrics.iconSmall)
            view.contentTintColor = .secondaryLabelColor
            return view
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> NSScrollView {
        let lists = context.coordinator, table = lists.table
        let scroll = table.plainList("s", in: scrolls ? NSScrollView() : StillScrollView())
        scroll.hasVerticalScroller = scrolls
        table.dataSource = lists
        table.delegate = lists
        table.target = lists
        table.action = #selector(Coordinator.clicked)
        table.doubleAction = #selector(Coordinator.opened)
        table.onReturn = { [weak lists] in lists?.opened() }
        table.menu = NSMenu()
        table.menu?.delegate = lists
        lists.show(sections)
        return scroll
    }
    public func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.show(sections) }
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard !scrolls else { return nil }
        let table = context.coordinator.table, rows = table.numberOfRows
        return CGSize(width: proposal.width ?? 0, height: rows > 0 ? table.rect(ofRow: rows - 1).maxY : 0)
    }

    enum Line {
        case section(Section, open: Bool)
        case note(String)
        case row(Row)

        /// What the line is, whatever it says now: a list with the same keys in the same order is the same list.
        var key: String {
            switch self {
            case .section(let section, _): "s " + section.id
            case .note(let text): "n " + text
            case .row(let row): "r " + row.id
            }
        }
        /// Everything the line shows. While it stays the same the line isn't drawn again.
        var stamp: String {
            switch self {
            case .section(let section, let open): "\(section.title) \(section.rows.count) \(open)"
            case .note(let text): text
            case .row(let row):
                [
                    row.key, row.iconKey, row.title, row.lead, row.detail, row.trailing, row.button?.title,
                    row.link?.title, row.tip, row.onHover ? "h" : nil, row.mono ? "m" : nil, row.path ? "p" : nil
                ]
                .map { $0 ?? "" }.joined(separator: "\u{1F}")
            }
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let table = KeyTable()
        private(set) var lines: [Line] = []
        private var sections: [Section] = []
        /// The sections folded by hand. It is the view's state and isn't kept.
        private var closed: Set<String> = []

        func show(_ sections: [Section]) {
            self.sections = sections
            let old = lines
            lines = sections.flatMap { section -> [Line] in
                let open = !closed.contains(section.id)
                let rows: [Line] =
                    section.rows.isEmpty ? (section.note.map { [.note($0)] } ?? []) : section.rows.map(Line.row)
                return [.section(section, open: open)] + (open ? rows : [])
            }
            guard old.map(\.key) == lines.map(\.key) else {
                // A few rows that came or went (a port, a fold of two) move the others instead of jumping them.
                let chosen = old.indices.contains(table.selectedRow) ? old[table.selectedRow].key : nil
                let places = table.rowPlaces { old.indices.contains($0) ? old[$0].key : nil }
                let was = Set(old.map(\.key)), now = Set(lines.map(\.key))
                table.reloadSettling(from: places, came: now.subtracting(was), gone: was.subtracting(now), lineKey) {
                    table.reloadData()
                    if let row = lines.firstIndex(where: { $0.key == chosen }) {
                        table.selectRowIndexes([row], byExtendingSelection: false)
                    }
                }
                return
            }
            let moved = IndexSet(lines.indices.filter { lines[$0].stamp != old[$0].stamp })
            guard !moved.isEmpty else { return }
            table.noteHeightOfRows(withIndexesChanged: moved)   // a row may have gained or lost its second line
            table.reloadData(forRowIndexes: moved, columnIndexes: [0])
        }

        private func lineKey(_ row: Int) -> String? { lines.indices.contains(row) ? lines[row].key : nil }

        private func row(_ id: String) -> Row? {
            for case .row(let row) in lines where row.id == id { return row }
            return nil
        }

        @objc func clicked() {
            guard lines.indices.contains(table.clickedRow) else { return }
            switch lines[table.clickedRow] {
            case .section(let section, _): fold(section.id)
            case .row(let row): row.click?()
            case .note: break
            }
        }
        /// Folds the section, or opens it again.
        func fold(_ id: String) {
            let opens = closed.remove(id) != nil
            if !opens { closed.insert(id) }
            show(sections)
            // The new heading's chevron turns from what the old one showed, once it has a size.
            guard let row = lines.firstIndex(where: { $0.key == "s " + id }) else { return }
            table.layoutSubtreeIfNeeded()
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionHeading)?.chevron?
                .turn(from: opens ? .pi / 2 : -.pi / 2)
        }
        @objc func opened() {
            guard lines.indices.contains(table.actedRow), case .row(let row) = lines[table.actedRow] else { return }
            (row.open ?? row.click)?()
        }

        public func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch lines[row] {
            case .section: TextSize.of(Metrics.rowSection)
            case .row(let row) where row.detail != nil: TextSize.of(Metrics.rowTwoLine)
            default: TextSize.of(Metrics.row)
            }
        }
        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            if case .note = lines[row] { return ListRowView(lights: { _ in false }) }
            return ListRowView()
        }
        public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .row = lines[row] { true } else { false }
        }
        public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            switch lines[row] {
            case .section(let section, let open): heading(section, open: open)
            case .note(let text):
                Cell([NSTextField.label(text, font: .ui(TextSize.row), color: .secondaryLabelColor)])
            case .row(let row): cell(row)
            }
        }

        public func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard lines.indices.contains(table.clickedRow), case .row(let row) = lines[table.clickedRow] else {
                return
            }
            for action in row.menu { menu.add(action.title, action.run) }
        }

        private func heading(_ section: Section, open: Bool) -> NSView {
            let heading = SectionHeading(
                section.title, count: section.rows.isEmpty ? nil : section.rows.count, open: open)
            heading.onPress = { [weak self] in self?.fold(section.id) }
            return heading
        }

        private func cell(_ row: Row) -> NSView {
            let id = row.id
            let title = NSTextField.label(
                row.title, font: .ui(TextSize.row), truncation: row.path ? .byTruncatingMiddle : .byTruncatingTail)
            var views: [NSView] = []
            if let key = row.key {
                let label = NSTextField.label(key, font: .uiDigits(TextSize.row))
                label.widthAnchor.constraint(equalToConstant: TextSize.of(SectionList.keyWidth)).isActive = true
                views.append(label)
            }
            if let icon = row.icon?() {
                icon.widthAnchor.constraint(equalToConstant: Metrics.appIcon).isActive = true
                views.append(icon)
            }
            views += [row.detail == nil ? title : twoLines(title, row), NSView()]
            var quiet: NSView?, shown: NSView?
            if let trailing = row.trailing {
                // What stands at the end gives way before the name does, and loses its start: a path's end says more.
                let label = NSTextField.label(
                    trailing, font: .uiDigits(TextSize.caption), color: .secondaryLabelColor,
                    truncation: .byTruncatingHead)
                label.setContentCompressionResistancePriority(.init(240), for: .horizontal)
                views.append(label)
                quiet = label
            }
            if let link = row.link {
                let button = PointerButton.link(link.title, font: .uiDigits(TextSize.caption)) { [weak self] in
                    self?.row(id)?.link?.run()
                }
                button.toolTip = link.tip
                views.append(button)
            }
            if let action = row.button {
                let button = ClosureButton(title: action.title) { [weak self] in self?.row(id)?.button?.run() }
                button.bezelStyle = .push
                button.controlSize = .small
                button.font = .ui(TextSize.caption)
                button.toolTip = action.tip
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                views.append(button)
                if row.onHover {
                    button.isHidden = true
                    shown = button
                }
            }
            let cell = Cell(views, quiet: shown == nil ? nil : quiet, shown: shown)
            cell.toolTip = row.tip
            return cell
        }

        private func twoLines(_ title: NSTextField, _ row: Row) -> NSView {
            let words = NSMutableAttributedString(
                string: row.lead.map { $0 + " " } ?? "", attributes: [.foregroundColor: NSColor.textOrange])
            words.append(
                NSAttributedString(
                    string: row.detail ?? "", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            let font = row.mono ? NSFont.uiMono(TextSize.caption) : .uiDigits(TextSize.caption)
            words.addAttribute(.font, value: font, range: NSRange(location: 0, length: words.length))
            let under = NSTextField(labelWithAttributedString: words)
            under.lineBreakMode = .byTruncatingTail
            under.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = NSStackView(views: [title, under])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = Metrics.lineGap
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return text
        }
    }

    /// A line's views in a row. Under the pointer `shown` takes the place of `quiet`: a port's Forward where its
    /// "all addresses" stood.
    final class Cell: NSView, Hoverable {
        private let quiet: NSView?, shown: NSView?

        init(_ views: [NSView], quiet: NSView? = nil, shown: NSView? = nil) {
            self.quiet = quiet
            self.shown = shown
            super.init(frame: .zero)
            let line = NSStackView(views: views)
            line.spacing = Metrics.gap
            line.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
            pin(line)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        func setHover(_ on: Bool) {
            guard let shown, shown.isHidden == on else { return }
            crossfade()
            shown.isHidden = !on
            quiet?.isHidden = on
        }
    }
}

/// The scroll view of a list or table that stands in a page that scrolls: it is as tall as its rows, and the wheel
/// goes on to the page around it.
public final class StillScrollView: NSScrollView {
    override public func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
