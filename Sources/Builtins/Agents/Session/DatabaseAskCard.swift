import AppKit
import Core
import DesignKit
import KelpKit

/// Over the foot of an agent's terminal while it waits for the user to allow a change to a database (`kelp db query`):
/// which database, the statement, the first rows of the change as its trial left them (each value that changes as it
/// was and as it becomes, `ChangePreview`), how many rows it changed, and Show Rows (its tab), Deny, Allow. What's
/// asked is read from the workspace's database runs (`db.activity`) when its row starts asking, its rows from
/// `db.result`; the answer goes as a permission's does. Made the first time this agent asks anything; it shows only
/// for a database's question.
@MainActor
final class DatabaseAskCard: NSView {
    private let app: AppModel, session: String, worktree: String
    private let title = NSTextField(labelWithString: "")
    private let sql = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let preview = ChangePreview()
    private lazy var showButton = NSButton(title: "", target: self, action: #selector(showRows))
    private var asking: DatabaseRun?

    init(app: AppModel, session: String, worktree: String) {
        self.app = app
        self.session = session
        self.worktree = worktree
        super.init(frame: .zero)
        let mark = NSImageView(image: .symbol("cylinder.split.1x2"))
        mark.contentTintColor = .textOrange
        title.font = .ui(TextSize.body, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sql.font = .uiMono(TextSize.caption)
        sql.textColor = .secondaryLabelColor
        sql.maximumNumberOfLines = 3
        sql.lineBreakMode = .byTruncatingTail
        detail.font = .ui(TextSize.row)
        let deny = NSButton(title: String(localized: "Deny"), target: self, action: #selector(denied))
        let allow = NSButton(title: String(localized: "Allow"), target: self, action: #selector(allowed))
        for button in [showButton, deny, allow] { button.bezelStyle = .push }   // no key: the terminal keeps its keys
        let head = NSStackView(views: [mark, title])
        head.spacing = Metrics.gap
        let buttons = NSStackView(views: [showButton, NSView(), deny, allow])
        buttons.spacing = Metrics.gapWide
        let stack = NSStackView(views: [head, sql, preview, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        for view in [sql, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Metrics.inset).isActive = true
        }
        let card = FloatingCard(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        isHidden = true
        // While its row asks (Allow / Deny): the change it waits on, read once, if what it asks is a database's.
        track(owner: self) { [app] in
            app.session(session).map { $0.asksPermission ? $0.summary : "" } ?? ""
        } changed: { [weak self] question in
            guard !question.isEmpty else { return self?.show(nil) ?? () }
            Task { [weak self] in
                let runs = await app.quiet(DatabaseActivity(worktreeId: worktree))?.runs ?? []
                self?.show(runs.first { $0.session == session && $0.state == .asks })
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ run: DatabaseRun?) {
        asking = run
        isHidden = run == nil
        guard let run else { return }
        sql.stringValue = run.sql
        say(run, nil)
        Task { [weak self, app, worktree] in
            let rows = await app.quiet(DatabaseResultRead(worktreeId: worktree, id: run.id)) ?? nil
            if self?.asking?.id == run.id { self?.say(run, rows) }
        }
    }

    /// The words and the rows: with the change's rows, the title says how many of which table, and the line under
    /// them how many more there are.
    private func say(_ run: DatabaseRun, _ rows: QueryResult?) {
        let who = app.session(session).map { app.catalog.name($0.agent) } ?? String(localized: "The agent")
        sql.isHidden = rows?.statements != nil   // several: each is on its line of the list
        if let parts = rows?.statements { return say(run, parts, who) }
        let shown = rows.map(preview.show) ?? 0
        preview.isHidden = shown == 0
        showButton.title = String(localized: "Show Rows")
        guard shown > 0, let rows, let table = rows.change?.tableName else {
            title.stringValue = String(localized: "\(who) wants to change \(run.database)")
            detail.stringValue =
                run.changed.map { String(localized: "\($0) rows would change. Tried, then rolled back.") }
                ?? String(localized: "It couldn't be tried first.")
            return
        }
        title.stringValue =
            rows.total == 1
            ? String(localized: "\(who) wants to change 1 row of \(table) in \(run.database)")
            : String(localized: "\(who) wants to change \(rows.total) rows of \(table) in \(run.database)")
        let more = rows.total - shown
        detail.stringValue =
            more > 0
            ? String(localized: "and \(more) more · tried, then rolled back")
            : String(localized: "Tried, then rolled back.")
        if more > 0 { showButton.title = String(localized: "Show All \(rows.total) Rows") }
    }

    /// Several statements asked as one: a line each, and that they're kept together or not at all.
    private func say(_ run: DatabaseRun, _ parts: [StatementResult], _ who: String) {
        let shown = preview.show(statements: parts)
        preview.isHidden = false
        title.stringValue = String(localized: "\(who) wants to change \(run.database)")
        let together = String(localized: "\(parts.count) statements in one transaction: all of them or none.")
        detail.stringValue =
            together + " "
            + (run.changed.map { String(localized: "\($0) rows would change. Tried, then rolled back.") } ?? "")
        showButton.title =
            parts.count > shown
            ? String(localized: "Show All \(parts.count) Statements") : String(localized: "Show Statements")
    }

    @objc private func showRows() {
        guard let run = asking else { return }
        app.workbench.open(DatabaseTabURI.uri(worktree: worktree, name: run.database, run: run.id), split: .right)
    }
    @objc private func allowed() { answer("allow") }
    @objc private func denied() { answer("deny") }
    private func answer(_ action: String) {
        Notifications.answer(app, session, action, question: app.session(session)?.summary)
    }
}
