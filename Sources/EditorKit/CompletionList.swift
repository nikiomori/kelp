import AppKit
import DesignKit

/// The list of what can go in at the cursor: a panel under it that never takes the keys, with the selected item's
/// documentation beside it. The text view sends it ↑ ↓ ↩ ⇥ and Esc while it's open.
@MainActor
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 380, docWidth: CGFloat = 280, mostRows = 9, mostDocLines = 12
    private let panel = NSPanel(
        contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
    private let table = NSTableView()
    private let doc = NSTextField(wrappingLabelWithString: "")
    private lazy var docCard: FloatingCard = {
        let padded = NSView()
        let inset = Metrics.inset
        padded.pin(doc, inset: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
        return FloatingCard(padded, radius: Metrics.radiusMD)
    }()
    private let row = NSStackView()
    /// The list's height: its rows, whatever the docs beside it need (`place`).
    private var listHeight: NSLayoutConstraint?
    /// Where the list was asked for, for placing it again when the docs beside it change.
    private var caret = NSRect.zero
    private weak var parent: NSWindow?
    private(set) var items: [CodeEditor.Completion] = []
    var onAccept: ((CodeEditor.Completion) -> Void)?
    var isOpen: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        let column = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let card = FloatingCard(scroll, radius: Metrics.radiusMD)
        doc.font = .ui(TextSize.caption)
        doc.textColor = .secondaryLabelColor
        // Long docs are cut at their end rather than growing the panel down the screen.
        doc.maximumNumberOfLines = Self.mostDocLines
        doc.cell?.truncatesLastVisibleLine = true
        doc.preferredMaxLayoutWidth = Self.docWidth - 2 * Metrics.inset
        row.setViews([card, docCard], in: .leading)
        row.alignment = .top
        row.spacing = Metrics.gap
        panel.contentView = row
        card.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        listHeight = card.heightAnchor.constraint(equalToConstant: 0)
        listHeight?.isActive = true
        docCard.widthAnchor.constraint(equalToConstant: Self.docWidth).isActive = true
    }

    /// Shows the list under `caret` (in screen coordinates), or over it when the screen ends first.
    func show(_ items: [CodeEditor.Completion], at caret: NSRect, in parent: NSWindow?) {
        self.items = items
        // A row fits the editor's line (its font and size, which Settings change), and grows with Text size too.
        let line = ceil(NSLayoutManager().defaultLineHeight(for: CodeEditor.font)) + CodeEditor.lineExtra
        table.rowHeight = max(TextSize.of(Metrics.row), line)
        table.reloadData()
        guard !items.isEmpty else { return close() }
        self.caret = caret
        self.parent = parent
        select(0)
        if !panel.isVisible {
            parent?.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var selected: CodeEditor.Completion? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    func move(by offset: Int) {
        guard !items.isEmpty else { return }
        select((table.selectedRow + offset + items.count) % items.count)
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        showDoc()   // a row that stays selected over a reload posts no change
    }

    private func showDoc() {
        let text = selected?.documentation ?? ""
        doc.stringValue = text
        docCard.isHidden = text.isEmpty
        place()
    }

    /// Sizes the panel to the list's rows or the docs beside them, whichever is taller, keeping the list's edge at the
    /// caret: its top under it, or its bottom over it when the screen ends first.
    private func place() {
        let rows = CGFloat(min(items.count, Self.mostRows)) * table.rowHeight + 2 * Metrics.lineGap
        listHeight?.constant = rows
        let height = docCard.isHidden ? rows : max(rows, docCard.fittingSize.height)
        let width = Self.width + Metrics.gap + Self.docWidth
        var originY = caret.minY - height - Metrics.lineGap
        row.alignment = .top
        if let floor = parent?.screen?.visibleFrame.minY, caret.minY - rows - Metrics.lineGap < floor {
            originY = caret.maxY + Metrics.lineGap
            row.alignment = .bottom
        }
        panel.setFrame(NSRect(x: caret.minX, y: originY, width: width, height: height), display: true)
    }

    @objc private func clicked() { if let selected { onAccept?(selected) } }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    /// The panel never takes the keys, so its selection would be the grey of a list out of focus. It is the accent's,
    /// as the list is what the keys move through.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ListRowView(selection: .selectedContentBackgroundColor)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showDoc() }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let icon = NSImageView(image: .symbol(Self.symbol(item.kind), item.kind))
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .chrome()
        let label = NSTextField(labelWithString: item.label)
        label.font = CodeEditor.font   // the code's font and size, as what it puts in
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        let detail = NSTextField(labelWithString: item.detail ?? "")
        detail.font = .ui(TextSize.caption)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let row = NSStackView(views: [icon, label, NSView(), detail])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        return row
    }

    private static func symbol(_ kind: String?) -> String {
        switch kind {
        case "method", "function", "constructor": "function"
        case "class", "struct", "interface", "enum": "cube"
        case "property", "field", "variable", "constant", "value": "v.square"
        case "keyword": "textformat"
        case "snippet": "curlybraces"
        case "module", "folder", "file": "shippingbox"
        default: "abc"   // plain words: circle.dotted is an agent's ring elsewhere
        }
    }
}
