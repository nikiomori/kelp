import AppKit
import Core
import DesignKit
import KelpKit

/// "db:<workspace>/<copy>?compare=<original>": how a branch's copy differs from the database it copies (`db.diff`),
/// one row a table: its structure and its rows, with the tables the same in both folded into one line. Copy as Text
/// copies what `kelp db diff` prints.
@MainActor
final class DatabaseCompareTab: KelpKit.TabContent {
    let uri: String
    let view = NSView()
    let address: DatabaseURI
    var title: String { DatabaseTab.title(address) }
    var icon: NSImage? { .symbol(DatabaseLook.symbol) }
    private let app: AppModel
    private let grid = ResultGrid()
    private let heading = NSTextField.label("", font: .ui(TextSize.row, weight: .semibold))
    private let loading = LoadingView(), empty = EmptyStateView()
    private var comparison: DatabaseComparison?
    private lazy var copy = TextButton(String(localized: "Copy as Text")) { [weak self] in
        self?.comparison.map { copyText($0.text) }
    }
    private lazy var tryAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in self?.read() }

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        address = DatabaseURI(uri) ?? DatabaseURI(worktree: "", name: "")
        heading.stringValue = title
        heading.lineBreakMode = .byTruncatingMiddle
        copy.isEnabled = false
        let bar = Bar.content([heading], [copy], stretching: heading)
        let column = NSStackView(views: [bar, grid.area])
        column.orientation = .vertical
        column.spacing = 0
        for part in [bar, grid.area] { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        view.pin(column)
        loading.place(in: grid.area)
        empty.place(in: grid.area)
        read()
    }

    func focus() { view.window?.makeFirstResponder(grid.table) }

    private func read() {
        empty.show(nil)
        loading.show(String(localized: "Comparing…"))
        Task { [weak self, app, address] in
            let (read, error) = await app.tryCall(DatabaseDiff(worktreeId: address.worktree, database: address.name))
            guard let self else { return }
            await loading.settled()
            loading.show(nil)
            guard let read else {
                return empty.showError(String(localized: "Couldn’t Compare"), text: error, buttons: [tryAgain])
            }
            comparison = read
            copy.isEnabled = true
            heading.stringValue = "\(read.title) ↔ \(read.original)"
            grid.show(
                columns: [String(localized: "table"), String(localized: "structure"), String(localized: "rows")],
                rows: Self.rows(read))
        }
    }

    /// A row for each table that differs, then one for those the same in both: "2 more · same · same".
    static func rows(_ comparison: DatabaseComparison) -> [[String?]] {
        let differ = comparison.differing
        let same = comparison.tables.count - differ.count
        let rows: [[String?]] = differ.map { [$0.name, structure($0), count($0)] }
        let word = String(localized: "same")
        return rows + (same > 0 ? [[String(localized: "\(same) more"), word, word]] : [])
    }

    /// "new table", "dropped", "same", or the columns that differ.
    static func structure(_ table: DatabaseComparison.Table) -> String {
        switch table.change {
        case .added: String(localized: "new table")
        case .dropped: String(localized: "dropped")
        case .same: String(localized: "same")
        case .changed: table.columns.joined(separator: ", ")
        }
    }

    /// The rows the copy has more or fewer ("+37", "−12"), or how many both have ("1,240").
    static func count(_ table: DatabaseComparison.Table) -> String? {
        switch (table.rows, table.was) {
        case (let rows?, let was?) where rows == was: rows.formatted()
        case (let rows?, let was?): (rows > was ? "+" : "−") + abs(rows - was).formatted()
        case (let rows?, nil): table.change == .added ? "+" + rows.formatted() : rows.formatted()
        case (nil, let was?): table.change == .dropped ? "−" + was.formatted() : nil
        case (nil, nil): nil
        }
    }
}
