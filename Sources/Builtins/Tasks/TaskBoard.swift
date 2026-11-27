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
    private let board = FlippedView()
    /// The narrowest a column gets before the board scrolls sideways.
    private static let narrowest: CGFloat = 160

    init(model: TasksModel) {
        self.model = model
        board.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = board
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // The board is the tab's width (wider only when the columns need it: then it scrolls sideways), and as tall as
        // its longest column or the tab.
        let wide = CGFloat(TaskColumn.allCases.count) * (Self.narrowest + Metrics.gapWide) + 2 * Metrics.pageInset
        let fitsTab = board.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        fitsTab.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fitsTab, board.widthAnchor.constraint(greaterThanOrEqualToConstant: wide),
            board.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        ])
        scroll.setAccessibilityLabel(String(localized: "Board"))
    }

    /// Lays the columns side by side, of one width, each hanging from the top.
    func show(_ columns: [(column: TaskColumn, rows: [TaskRow])]) {
        board.subviews.forEach { $0.removeFromSuperview() }
        var previous: NSView?
        for (column, rows) in columns {
            let view = self.column(column, rows)
            view.translatesAutoresizingMaskIntoConstraints = false
            board.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: board.topAnchor, constant: Metrics.pageTop),
                previous.map { view.leadingAnchor.constraint(equalTo: $0.trailingAnchor, constant: Metrics.gapWide) }
                    ?? view.leadingAnchor.constraint(equalTo: board.leadingAnchor, constant: Metrics.pageInset),
                board.bottomAnchor.constraint(greaterThanOrEqualTo: view.bottomAnchor, constant: Metrics.pageTop)
            ])
            if let previous { view.widthAnchor.constraint(equalTo: previous.widthAnchor).isActive = true }
            // As tall as its cards, so they hang from the top (a taller stack would keep them at its foot).
            view.heightAnchor.constraint(equalToConstant: view.fittingSize.height).isActive = true
            previous = view
        }
        previous?.trailingAnchor.constraint(equalTo: board.trailingAnchor, constant: -Metrics.pageInset).isActive = true
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
        let app = model.app
        let cell = TaskCell(app, row, place: [model.projectName(row.repo), row.place].joined(separator: " › "))
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
