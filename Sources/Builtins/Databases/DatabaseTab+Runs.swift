// A database tab's runs and its agent: the query runs it shows, the question an agent's change asks, the foot.
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

extension DatabaseTab {
    // MARK: Runs

    func record(_ id: String) -> DatabaseRun? {
        app.latest(DatabasesEvent.self, address.worktree)?.runs.first { $0.id == id }
    }

    func showRun(_ id: String) async {
        arrange()
        sidebar.current = nil
        let record = record(id)
        sqlText.stringValue = record?.sql ?? ""
        let result = await app.quiet(DatabaseResultRead(worktreeId: address.worktree, id: id)) ?? nil
        grid.editable = false
        grid.source = nil
        grid.show(columns: result?.columns ?? [], rows: result?.rows ?? [])
        if let error = record?.error, record?.state != .asks {
            empty.showError(Self.stateTitle(record?.state ?? .failed), text: error)
        } else if result == nil {
            empty.show(
                String(localized: "Not Kept"), symbol: "clock",
                text: String(localized: "Kelp keeps the rows of the latest runs only."))
        } else if result?.columns.isEmpty == true, let changed = record?.changed, record?.state == .done {
            empty.show(Self.rows(changed, changed: true).capitalizedFirst, symbol: "checkmark.circle")
        } else {
            empty.show(
                result?.rows.isEmpty == true && result?.columns.isEmpty == false ? String(localized: "No Rows") : nil)
        }
        let who = record?.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "You")
        status.stringValue = [who, record.map { shortAgo($0.at) }, record.map(Self.summary)].compactMap { $0 }
            .joined(separator: " · ")
        footChanged()
    }

    static func stateTitle(_ state: DatabaseRun.State) -> String {
        switch state {
        case .denied: String(localized: "Denied")
        case .refused: String(localized: "Refused")
        default: String(localized: "Failed")
        }
    }

    /// "1 row", "200 rows", "3 rows changed": the plural right.
    static func rows(_ n: Int, changed: Bool = false) -> String {
        let count = n == 1 ? String(localized: "1 row") : String(localized: "\(n.formatted()) rows")
        return changed ? count + " " + String(localized: "changed") : count
    }

    /// "84 ms", "1.5 s": how long a read took.
    nonisolated static func took(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func summary(_ run: DatabaseRun) -> String {
        switch run.state {
        case .asks:
            return run.changed.map { rows($0) + " " + String(localized: "would change: shown as they would be") }
                ?? String(localized: "Waits for your answer")
        case .done:
            let what = run.changed.map { rows($0, changed: true) } ?? rows(run.rows ?? 0)
            return [what, run.ms.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · ")
        default: return run.error ?? ""
        }
    }

    /// The runs of this database changed: the bar follows the one that asks, a run shown takes its new state, the
    /// list and the details their latest.
    func runsChanged() {
        let runs = app.latest(DatabasesEvent.self, address.worktree)?.runs.filter { $0.database == address.name } ?? []
        let was = asking
        asking = runs.first { $0.state == .asks }
        askBar.isHidden = asking == nil
        if let asking {
            let who =
                asking.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "An agent")
            askText.stringValue =
                asking.changed.map { String(localized: "\(who) wants to change \(Self.rows($0)) in \(address.name)") }
                ?? String(localized: "\(who) wants to change \(address.name)")
            askText.toolTip = asking.sql
        }
        if case .run(let id) = mode, was?.id == id, asking?.id != id { Task { await showRun(id) } }
        // An agent's runs and any change: the tab's own reads of a page aren't history.
        sidebar.runs = runs.filter { $0.session != nil || $0.changed != nil }
        detailsChanged()
        capsuleChanged()
    }

    @objc func showAsked() {
        guard let asking else { return }
        Task { await leave(to: .run(asking.id)) }
    }
    @objc func allowAsked() { answer("allow") }
    @objc func denyAsked() { answer("deny") }
    private func answer(_ action: String) {
        guard let session = asking?.session else { return }
        Notifications.answer(app, session, action, question: app.session(session)?.summary)
    }

    func openRun(_ run: DatabaseRun, toEditor: Bool) {
        guard toEditor else {
            Task { await leave(to: .run(run.id)) }
            return
        }
        editor.setText(run.sql)
        Task { await leave(to: .query) }
    }

    /// The user's statement, as theirs: a change runs without a question. Its error shows where the rows would.
    func query(_ sql: String, limit: Int = ResultGrid.shown) async -> QueryResult? {
        let (result, error) = await app.tryCall(
            DatabaseQuery(worktreeId: address.worktree, database: address.name, sql: sql, limit: limit))
        if let error {
            grid.show(columns: [], rows: [])
            empty.showError(String(localized: "\(address.name) said no"), text: error)
            status.stringValue = ""
        }
        return result
    }

    /// Away from edits only once they're saved or dropped.
    func leave(to next: Mode) async {
        if isEdited, await !close() { return }
        chosen = true
        mode = next
        grid.orders = []
        page = 0
        part.selectedSegment = 0
        if next.table == nil { filters.clear() }
        switch next {
        case .table(let name): await showTable(name)
        case .run(let id): await showRun(id)
        case .query: startedQuery()
        }
    }

    /// A table in this tab (it replaces the one shown), or in a tab of its own.
    func openTable(_ name: String, pin: Bool) {
        if pin {
            app.workbench.open(DatabaseURI(worktree: address.worktree, name: address.name, table: name).uri)
        } else {
            filters.clear()
            Task { await leave(to: .table(name)) }
        }
    }

    // MARK: The foot and the agent

    func footChanged() {
        let edits = grid.edits.count
        changes.stringValue =
            edits == 0 ? "" : edits == 1 ? String(localized: "1 change") : String(localized: "\(edits) changes")
        for v in [save, discard, showSQL] { v.isHidden = edits == 0 }
        let picked = grid.selectedRows.count, agent = agentToAsk
        ask.isHidden = picked == 0 || agent == nil || edits > 0 || mode == .query
        if let agent {   // short: the count is the selection on screen, and in the tooltip
            let name = app.catalog.name(agent.agent)
            ask.title = String(localized: "Ask \(name)")
            ask.image = app.catalog.icon(agent.agent, size: 14)
            ask.imagePosition = .imageLeading
            ask.toolTip = String(localized: "Ask \(name) about \(Self.rows(picked))")
        }
        detailsChanged()
    }

    /// The chat a run came from, else the one every "send to agent" picks (`FileActions.targetAgent`).
    var agentToAsk: Session? {
        if case .run(let id) = mode, let sid = record(id)?.session, let ran = app.session(sid), ran.status != .exited {
            return ran
        }
        return FileActions(app).targetAgent
    }

    @objc func askAgent() {
        guard let agent = agentToAsk else { return }
        let picked = Array(grid.selectedRows.prefix(50))
        let source = mode.table.map { String(localized: "the table \($0)") } ?? sqlText.stringValue
        send("Rows of \(address.name) (\(source)):\n" + grid.text(picked) + "\n", to: agent)
    }

    func askAbout(_ table: String) {
        guard let agent = agentToAsk else { return NSSound.beep() }
        send("About " + DatabasesPanel.mention(table, in: address.name) + ": ", to: agent)
    }

    private func send(_ text: String, to agent: Session) {
        Task {
            guard await app.call(SessionSend(id: agent.id, text: text, enter: false)) != nil else { return }
            app.workbench.focus(session: agent.id)
        }
    }
}
