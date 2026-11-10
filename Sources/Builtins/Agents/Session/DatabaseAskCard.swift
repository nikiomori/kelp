import AppKit
import Core
import DesignKit
import KelpKit

/// Over the foot of an agent's terminal while it waits for the user to allow a change to a database (`kelp db query`):
/// which database, the statement, how many rows the trial changed, and Show Rows (its tab), Deny, Allow. What's asked
/// is read from the workspace's database runs (`db.activity`) when its row starts asking; the answer goes as a
/// permission's does. Made the first time this agent asks anything; it shows only for a database's question.
@MainActor
final class DatabaseAskCard: NSView {
    private let app: AppModel, session: String, worktree: String
    private let title = NSTextField(labelWithString: "")
    private let sql = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var asking: DatabaseRun?

    init(app: AppModel, session: String, worktree: String) {
        self.app = app
        self.session = session
        self.worktree = worktree
        super.init(frame: .zero)
        let mark = NSImageView(image: .symbol("cylinder.split.1x2"))
        mark.contentTintColor = .textOrange
        title.font = .ui(13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sql.font = .uiMono(11)
        sql.textColor = .secondaryLabelColor
        sql.maximumNumberOfLines = 3
        sql.lineBreakMode = .byTruncatingTail
        detail.font = .ui(12)
        let show = NSButton(title: String(localized: "Show Rows"), target: self, action: #selector(showRows))
        let deny = NSButton(title: String(localized: "Deny"), target: self, action: #selector(denied))
        let allow = NSButton(title: String(localized: "Allow"), target: self, action: #selector(allowed))
        for button in [show, deny, allow] { button.bezelStyle = .push }   // no key: the terminal keeps its keys
        let head = NSStackView(views: [mark, title])
        head.spacing = Metrics.gap
        let buttons = NSStackView(views: [show, NSView(), deny, allow])
        buttons.spacing = Metrics.gapWide
        let stack = NSStackView(views: [head, sql, detail, buttons])
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
        let who = app.session(session).map { app.catalog.name($0.agent) } ?? String(localized: "The agent")
        title.stringValue = String(localized: "\(who) wants to change \(run.database)")
        sql.stringValue = run.sql
        detail.stringValue =
            run.changed.map { String(localized: "\($0) rows would change. Tried, then rolled back.") }
            ?? String(localized: "It couldn't be tried first.")
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
