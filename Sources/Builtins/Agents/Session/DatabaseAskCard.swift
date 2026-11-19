import AppKit
import Core
import DesignKit
import KelpKit

/// A card over the bottom of an agent's terminal, shown while the agent waits for the user to allow a change to a
/// database (`kelp db query`). It shows the database, the statement, and the first rows of the change as the trial run
/// left them (`ChangePreview` shows each changed value as it was and as it becomes). It says how many rows changed,
/// and offers Show Rows (which opens the database's tab), Deny and Allow. When the agent's row starts asking, the card
/// reads the question from the workspace's database runs (`db.activity`) and the rows from `db.result`. The answer is
/// sent the same way as an answer to a permission prompt. The card is made the first time this agent asks anything,
/// but it shows only for a database's question.
@MainActor
final class DatabaseAskCard: NSView {
    private let app: AppModel, session: String, worktree: String
    private let title = NSTextField.label("", font: .ui(TextSize.body, weight: .semibold))
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
        sql.font = .uiMono(TextSize.caption)
        sql.textColor = .secondaryLabelColor
        sql.maximumNumberOfLines = 3
        sql.lineBreakMode = .byTruncatingTail
        detail.font = .ui(TextSize.row)
        let deny = NSButton(title: String(localized: "Deny"), target: self, action: #selector(denied))
        let allow = NSButton(title: String(localized: "Allow"), target: self, action: #selector(allowed))
        for button in [showButton, deny, allow] { button.bezelStyle = .push }   // none takes Return, the terminal does
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
        pin(FloatingCard(stack))
        isHidden = true
        // While the agent's row asks for Allow or Deny, the card reads once the change the agent waits on, and shows
        // it if the question is about a database.
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

    /// Fills in the text and the rows. When the change's rows are known, the title says how many rows of which table
    /// change, and the line under the rows says how many more there are.
    private func say(_ run: DatabaseRun, _ rows: QueryResult?) {
        let who = app.session(session).map { app.catalog.name($0.agent) } ?? String(localized: "The agent")
        sql.isHidden = rows?.statements != nil   // with several statements, each has its own line
        if let parts = rows?.statements { return say(run, parts, who) }
        let shown = rows.map(preview.show) ?? 0
        preview.isHidden = shown == 0
        showButton.title = String(localized: "Show Rows")
        guard shown > 0, let rows, let table = rows.change?.tableName else {
            title.stringValue = String(localized: "\(who) wants to change \(run.database)")
            detail.stringValue =
                run.changed.map { String(localized: "\($0) rows would change. Tried, then rolled back.") }
                ?? String(localized: "It couldn’t be tried first.")
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

    /// Fills in the card for several statements asked for as one. Each gets a line, and a note says that they all
    /// apply or none do.
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
