import AppKit
import Core
import DesignKit
import KelpKit

/// The Tasks tab's Board: the chosen list in the Agents Overview's stages, with Ideas and Plan before them. Each
/// task is the list's row on a card; its column is worked out (`TaskViews.board`), never dragged to. A double click
/// shows the line on its page, a right click its menu.
@MainActor
final class TaskBoard {
    let scroll = NSScrollView()
    private let model: TasksModel
    private let columns = NSStackView()
    /// The narrowest a column gets before the board scrolls sideways.
    private static let narrowest: CGFloat = 160

    init(model: TasksModel) {
        self.model = model
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = Metrics.gapWide
        columns.edgeInsets = NSEdgeInsets(
            top: Metrics.pageTop, left: Metrics.pageInset, bottom: Metrics.pageTop, right: Metrics.pageInset)
        let flip = FlippedView()
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.pin(columns)
        scroll.documentView = flip
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let wide = CGFloat(TaskColumn.allCases.count) * (Self.narrowest + Metrics.gapWide) + 2 * Metrics.pageInset
        NSLayoutConstraint.activate([
            flip.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            flip.widthAnchor.constraint(greaterThanOrEqualToConstant: wide),
            flip.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        ])
        scroll.setAccessibilityLabel(String(localized: "Board"))
    }

    func show(_ board: [(column: TaskColumn, rows: [TaskRow])]) {
        columns.setViews(board.map { column($0.column, $0.rows) }, in: .leading)
    }

    private func column(_ column: TaskColumn, _ rows: [TaskRow]) -> NSView {
        let heading = SectionHeading(column.title, count: rows.count)
        let stack = NSStackView(views: [heading] + rows.map(card))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gap
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if rows.isEmpty {   // an empty column stays, so the others don't move
            let none = NSTextField.label("—", font: .ui(TextSize.caption), color: .tertiaryLabelColor)
            stack.addArrangedSubview(none)
        }
        return stack
    }

    private func card(_ row: TaskRow) -> NSView {
        let app = model.app, cell = TaskCell()
        cell.show(
            row, chats: (row.task.chats ?? []).compactMap(app.session),
            place: [model.projectName(row.repo), row.place].joined(separator: " › "),
            agent: app.catalog.name(TaskActions.lastAgent(app)),
            icon: { app.catalog.icon($0, size: Metrics.iconSmall) })
        cell.onToggle = { cancel in cancel ? TaskActions.set(app, row, .cancelled) : TaskActions.toggle(app, row) }
        cell.onRun = { TaskActions.run(app, row) }
        cell.onMenu = { view in
            let menu = NSMenu()
            TaskActions.fill(menu, app, row)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
        let card = TaskCard(asks: row.work == .asks)
        card.onOpen = { TaskActions.open(app, row) }
        card.menuFor = {
            let menu = NSMenu()
            TaskActions.fill(menu, app, row)
            return menu
        }
        card.pin(cell)
        card.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.rowTwoLine)).isActive = true
        return card
    }
}

/// A card's ground: the list's rest fill with the card's corners, an orange edge when its agent asks.
@MainActor
private final class TaskCard: NSView {
    var onOpen: () -> Void = {}
    var menuFor: () -> NSMenu? = { nil }
    private let asks: Bool

    init(asks: Bool) {
        self.asks = asks
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = Metrics.radiusMD
        layer?.backgroundColor = NSColor.fillRest.cgColor
        layer?.borderWidth = asks ? Metrics.strokeBold : 0
        layer?.borderColor = NSColor.systemOrange.cgColor
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onOpen() } else { super.mouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuFor() }
}
