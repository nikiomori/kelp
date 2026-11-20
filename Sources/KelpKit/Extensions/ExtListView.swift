import AppKit
import Core
import DesignKit

// MARK: list views

/// An extension's list panel: what its command prints, one row per item, on the inspector's rows (`ListRowView`) as
/// every other panel has them. Double-click or Return runs the first action, a right-click lists them all, and a row
/// with `drag` drags that file. Its rows are in `ExtListView+Rows.swift`.
@MainActor
final class ExtListView: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let def: ExtManifest.ListDef
    let folder: URL
    let app: AppModel
    let table = KeyTable()
    private(set) var items: [JSONValue] = []
    /// Each row's key (`keys`), in the rows' order.
    private var rowKeys: [String] = []
    private var error: String?
    private var answered = false   // the command has answered once (no "empty" before that)
    private var loop: Task<Void, Never>?
    private lazy var failureBar = FailureBar { [weak self] in self?.reload() }
    private let empty = EmptyStateView()
    private lazy var loading = LoadingView(
        rows: true, rowHeight: def.subtitle == nil ? Metrics.row : Metrics.rowTwoLine)
    private lazy var tryAgain = ClosureButton(title: String(localized: "Try Again")) { [weak self] in self?.reload() }
    private lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More Actions")) {
        [weak self] in self?.showMore()
    }

    init(def: ExtManifest.ListDef, folder: URL, app: AppModel) {
        self.def = def
        self.folder = folder
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = table.plainList("row")
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onReturn = { [weak self] in self.map { $0.runFirst(on: $0.table.selectedRow) } }
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // The bar every panel has: the leading side is for the panel's subject (its tab names it), and the actions sit
        // at the end before ⋯ (Refresh).
        let actions = (def.toolbar ?? []).enumerated().map { toolbarButton($1, $0) }
        let top = failureBar.under(Bar.panel([], actions + [more]))
        let content = stacked(top, scroll)
        empty.place(in: content, under: top)
        loading.place(in: content, under: top)
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Another workspace runs the command again, in its folder; what is shown stays until the answer.
        track(owner: self, now: false) { [app] in
            app.workbench.workspaceId
        } changed: { [weak self] _ in
            if self?.loop != nil { self?.start() }
        }
    }
    // The command runs only while the panel is on screen.
    override func viewDidAppear() {
        super.viewDidAppear()
        start()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        loop?.cancel()
        loop = nil
    }
    private func start() {
        loop?.cancel()
        let every = def.refresh, app = self.app
        loop = Task { [weak self] in
            await ExtListView.refreshing(every: every, away: { app.away }) { await self?.refresh() }
        }
    }

    private func showMore() {
        let menu = NSMenu()
        menu.add(String(localized: "Refresh")) { [weak self] in self?.reload() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + Metrics.lineGap * 2), in: more)
    }

    /// A toolbar action: the first in words on the grey plate (`TextButton`: a worded button has no symbol), the
    /// others as icons, or in words without a symbol. A `run` command that takes over a second shows a spinner in the
    /// button's place, and the button can't be pressed again until it ends.
    private func toolbarButton(_ action: ExtManifest.ActionDef, _ index: Int) -> PointerButton {
        let button: PointerButton
        if index == 0 {
            button = TextButton(action.title)
        } else if let icon = action.icon {
            button = IconButton(.symbol(icon, action.title), tip: action.title) {}
        } else {
            button = PointerButton(title: action.title) {}
            button.font = .ui(TextSize.row)
            button.padding = Metrics.gap
        }
        button.onClick = { [weak self, weak button] in
            guard let self else { return }
            ExtActions(app).perform(
                action, item: nil, folder: folder, busy: { on in button.map { Self.busy($0, on) } }
            ) { [weak self] in self?.reload() }
        }
        return button
    }

    /// Shows a button at work: the spinner stands where its symbol or its words were (which keep their room).
    private static func busy(_ button: PointerButton, _ on: Bool) {
        button.isEnabled = !on
        if let icon = button as? IconButton { return icon.busy = on }
        let spinner = button.subviews.first { $0 is NSProgressIndicator } as? NSProgressIndicator
        if on, spinner == nil {
            let made = NSProgressIndicator()
            made.style = .spinning
            made.controlSize = .small
            made.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(made)
            NSLayoutConstraint.activate([
                made.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                made.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            made.startAnimation(nil)
            let clear: [NSAttributedString.Key: Any] = [
                .font: button.font ?? .ui(TextSize.row), .foregroundColor: NSColor.clear
            ]
            button.attributedTitle = NSAttributedString(string: button.title, attributes: clear)
        } else if !on, let spinner {
            spinner.removeFromSuperview()
            let words = button.title
            button.title = words   // in their colour again
        }
    }

    /// Each row's key: its title, numbered where titles repeat. A refresh keeps a row, and its selection, while its
    /// other fields change (a container's "Up 5 minutes"); keyed by position, the selection moved to another row when
    /// one above it went.
    private func keys(_ items: [JSONValue]) -> [String] {
        let actions = ExtActions(app)
        var seen: [String: Int] = [:]
        return items.map { item in
            let title = actions.expand(def.title ?? "${name}", item: item, quote: false)
            seen[title, default: 0] += 1
            return seen[title] == 1 ? title : "\(title)\u{1}\(seen[title] ?? 0)"
        }
    }

    /// Runs `run` now, then again `seconds` (at least 1) after each run ends, so a command slower than its interval
    /// never runs twice at once. While the window is away nobody sees the list: it only looks again every 5 s whether
    /// to run. No `seconds` (or 0): once.
    static func refreshing(
        every seconds: Double?, away: @MainActor () -> Bool, run: @MainActor () async -> Void,
        pause: @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) async {
        var first = true
        while !Task.isCancelled {
            if first || !away() { await run() }
            first = false
            guard let seconds, seconds > 0 else { return }
            await pause(away() ? 5 : max(seconds, 1))
        }
    }

    func reload() { Task { [weak self] in await self?.refresh() } }

    private func refresh() async {
        let cmd = ExtActions(app).expand(def.command, item: nil, quote: true)
        let cwd = IDEContext.of(app).workspace?.path ?? folder.path
        // Only the first wait shows the rows' outline, a second in; a timed refresh keeps what is shown. Once shown,
        // the outline stays long enough not to blink.
        if !answered { loading.wait(String(localized: "Running the list’s command…")) }
        let result = await Shell.run(app, cmd, cwd: cwd, extension: folder.lastPathComponent)
        await loading.settled()
        loading.show(nil)
        answered = true
        if result.code != 0, result.stdout.isEmpty {
            error =
                result.stderr.isEmpty
                ? String(localized: "Exit code \(result.code)") : String(result.stderr.suffix(600))
        } else {
            error = nil
            show(Self.parse(result.stdout))
        }
        showState()
    }

    /// Puts the new rows in. Up to three rows coming or going fade while their neighbours move; more change at once.
    /// The selected row stays selected while it is there.
    private func show(_ new: [JSONValue]) {
        guard new != items else { return }   // the same rows aren't drawn again, so the one under the pointer stays lit
        let old = rowKeys
        let picked = old.indices.contains(table.selectedRow) ? old[table.selectedRow] : nil
        let places = table.rowPlaces { old.indices.contains($0) ? old[$0] : nil }
        items = new
        rowKeys = keys(new)
        let now = rowKeys
        table.reloadSettling(
            from: places, came: Set(now).subtracting(old), gone: Set(old).subtracting(now),
            { now.indices.contains($0) ? now[$0] : nil }
        ) {
            table.reloadData()
            if let picked, let row = now.firstIndex(of: picked) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
    }

    /// With rows, a failed refresh is a line over them. With none, the failure, or the empty state, takes their place.
    private func showState() {
        failureBar.show(items.isEmpty ? nil : error)
        if let error, items.isEmpty {
            empty.showError(
                String(localized: "Couldn’t Run the List’s Command"), text: nil, fix: error, buttons: [tryAgain])
        } else if items.isEmpty {
            // A field's icon names no symbol here.
            let symbol = def.icon.map { $0.contains("${") ? "tray" : $0 } ?? "tray"
            empty.show(def.empty ?? String(localized: "Nothing Here"), symbol: symbol)
        } else {
            empty.show(nil)
        }
    }

    /// A JSON array, or one JSON object per line.
    static func parse(_ text: String) -> [JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
            case .array(let array)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            return array
        }
        return trimmed.split(whereSeparator: \.isNewline).compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }
    }
}
