import AppKit
import DesignKit

/// The list of what can go in at the cursor: a panel under it that never takes the keys, with a selected item's documentation
/// beside it. The text view sends it ↑ ↓ ↩ ⇥ and Esc while it's open.
@MainActor
final class CompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 380, docWidth: CGFloat = 280, mostRows = 9
    private let panel = NSPanel(
        contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
    private let table = NSTableView()
    private let doc = NSTextField(wrappingLabelWithString: "")
    private lazy var docCard = FloatingCard(doc, radius: Metrics.radiusMD)
    private(set) var items: [CodeEditor.Completion] = []
    var onAccept: ((CodeEditor.Completion) -> Void)?
    var isOpen: Bool { panel.isVisible }
    private var docWidthOn: NSLayoutConstraint?

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
        table.rowHeight = Metrics.row
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
        doc.font = .ui(11)
        doc.textColor = .secondaryLabelColor
        let row = NSStackView(views: [card, docCard])
        row.alignment = .top
        row.spacing = Metrics.gap
        panel.contentView = row
        card.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        card.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        docCard.widthAnchor.constraint(equalToConstant: Self.docWidth).isActive = true
    }

    /// Under `caret` (in screen coordinates), or over it when the screen ends first.
    func show(_ items: [CodeEditor.Completion], at caret: NSRect, in parent: NSWindow?) {
        self.items = items
        table.reloadData()
        guard !items.isEmpty else { return close() }
        select(0)
        let height = CGFloat(min(items.count, Self.mostRows)) * Metrics.row + 2 * Metrics.lineGap
        let width = Self.width + Metrics.gap + Self.docWidth
        var y = caret.minY - height - Metrics.lineGap
        if let floor = parent?.screen?.visibleFrame.minY, y < floor { y = caret.maxY + Metrics.lineGap }
        panel.setFrame(NSRect(x: caret.minX, y: y, width: width, height: height), display: true)
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

    func move(by n: Int) {
        guard !items.isEmpty else { return }
        select((table.selectedRow + n + items.count) % items.count)
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        let text = selected?.documentation ?? ""
        doc.stringValue = text
        docCard.isHidden = text.isEmpty
    }

    @objc private func clicked() { if let selected { onAccept?(selected) } }

    func numberOfRows(in t: NSTableView) -> Int { items.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableViewSelectionDidChange(_ n: Notification) {
        let text = selected?.documentation ?? ""
        doc.stringValue = text
        docCard.isHidden = text.isEmpty
    }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let icon = NSImageView(
            image: NSImage(systemSymbolName: Self.symbol(item.kind), accessibilityDescription: item.kind) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .chrome()
        let label = NSTextField(labelWithString: item.label)
        label.font = .uiMono(12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        let detail = NSTextField(labelWithString: item.detail ?? "")
        detail.font = .ui(11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let row = NSStackView(views: [icon, label, NSView(), detail])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gap, bottom: 0, right: Metrics.gap)
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
        default: "circle.dotted"
        }
    }
}
