// A database tab's runs and its agent: the runs it shows, the question an agent's change asks, and the foot.
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
        let read = await app.tryCall(DatabaseResultRead(worktreeId: address.worktree, id: id)),
            result = read.value ?? nil
        grid.editable = false
        grid.source = nil
        if let parts = result?.statements {   // several statements ran as one: a line each, with the rows it changed
            grid.show(
                columns: [String(localized: "statement"), String(localized: "rows changed")],
                rows: parts.map { [$0.sql, $0.changed.map(String.init)] })
            grid.table.tableColumns.dropFirst().first.map(grid.sizeToFit)   // fits as much of the statement as it can
        } else {
            grid.show(columns: result?.columns ?? [], rows: result?.rows ?? [])
            grid.show(change: result?.change, changed: result?.changedColumns ?? [])
        }
        if let error = record?.error, record?.state != .asks {
            empty.showError(Self.stateTitle(record?.state ?? .failed), text: error)
        } else if result?.statements != nil {
            empty.show(nil)
        } else if let error = read.error {   // a failed read doesn't mean the rows weren't kept
            empty.showError(String(localized: "Can’t Read \(address.name)"), text: error)
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

    /// "1 row", "200 rows", "3 rows changed", with the plural right. Each is one phrase, so it is translated whole.
    static func rows(_ n: Int, changed: Bool = false) -> String {
        guard changed else { return n == 1 ? String(localized: "1 row") : String(localized: "\(n.formatted()) rows") }
        return n == 1 ? String(localized: "1 row changed") : String(localized: "\(n.formatted()) rows changed")
    }

    /// "12 rows", or "1,000 of 12,408 rows shown" when a statement gave more than the grid holds.
    static func shown(_ shown: Int, of total: Int) -> String {
        total > shown
            ? String(localized: "\(shown.formatted()) of \(total.formatted()) rows shown") : rows(total)
    }

    /// How long a read took: "84 ms", "1.5 s".
    nonisolated static func took(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    static func summary(_ run: DatabaseRun) -> String {
        switch run.state {
        case .asks:
            return run.changed.map {
                $0 == 1
                    ? String(localized: "1 row would change: shown as it would be")
                    : String(localized: "\($0.formatted()) rows would change: shown as they would be")
            } ?? String(localized: "Waits for your answer")
        case .done:
            let what = run.changed.map { rows($0, changed: true) } ?? rows(run.rows ?? 0)
            return [what, run.ms.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · ")
        default: return run.error ?? ""
        }
    }

    /// Called when this database's runs changed. The bar follows the run that asks, a run on screen takes its new
    /// state, and the list and the details show their latest.
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
        // History lists an agent's runs and any change; the tab's own reads of a page aren't history.
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
        guard let asking, let session = asking.session else { return }
        Notifications.answer(app, session, action, question: app.session(session)?.summary, run: asking.id)
    }

    func openRun(_ run: DatabaseRun, toEditor: Bool) {
        guard toEditor else {
            Task { await leave(to: .run(run.id)) }
            return
        }
        editor.setText(run.sql)
        Task { await leave(to: .query) }
    }

    /// Runs the user's statement as the user's own, so a change runs without a question. Its error shows where the
    /// rows would. A read of `table`'s rows that fails while its rows show keeps them, under a line with Try Again.
    func query(_ sql: String, limit: Int = ResultGrid.shown, reading table: String? = nil) async -> QueryResult? {
        let (result, error) = await app.tryCall(
            DatabaseQuery(worktreeId: address.worktree, database: address.name, sql: sql, limit: limit))
        let shown = table != nil && grid.source?.table == table && !grid.columns.isEmpty
        // The tab may have gone on to show something else meanwhile; then this read's failure isn't said over it.
        guard table.map({ sidebar.current == $0 }) ?? (mode == .query) else { return result }
        failureBar.show(shown ? error : nil)
        if let error, !shown {
            grid.show(columns: [], rows: [])
            if table == nil {
                empty.showError(
                    String(localized: "\(address.name) Said No"), text: error, buttons: askAbout(sql, said: error))
            } else {
                empty.showError(
                    String(localized: "Can’t Read \(address.name)"), text: error,
                    buttons: [tryAgain()] + askAbout(sql, said: error))
            }
            status.stringValue = ""
        }
        return result
    }

    /// Try Again under a read that failed: it reads what the tab shows again.
    func tryAgain() -> NSButton {
        let again = ClosureButton(title: String(localized: "Try Again")) { [weak self] in self?.refresh() }
        again.bezelStyle = .push
        return again
    }

    /// The buttons under a statement the database refused: Ask <agent>, which puts the statement and what the
    /// database said in the agent's prompt. There are none when there is no agent to ask.
    private func askAbout(_ sql: String, said error: String) -> [NSButton] {
        guard let agent = agentToAsk else { return [] }
        let ask = ClosureButton(title: String(localized: "Ask \(app.catalog.name(agent.agent))")) { [weak self] in
            guard let self else { return }
            send("This statement fails on \(address.name):\n\(sql)\n\nThe database says: \(error)\n", to: agent)
        }
        return [ask]
    }

    /// Leaves edit mode for `next`, but only once the edits are saved or dropped.
    func leave(to next: Mode) async {
        if isEdited, await !close() { return }
        chosen = true
        mode = next
        readingEnded()   // a read still on its way is for what the tab showed: its wheel stops
        rowCount.stringValue = ""
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

    /// Opens a table in this tab, in place of the one shown, or in a tab of its own.
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
        for v in [save, discardButton, showSQL] { v.isHidden = edits == 0 }
        if case .run(let id) = mode, let run = record(id) {
            undoChange.isHidden = !Self.undoable(run)
        } else {
            undoChange.isHidden = true
        }
        let picked = grid.selectedRows.count, agent = agentToAsk
        ask.isHidden = picked == 0 || agent == nil || edits > 0 || mode == .query
        if let agent {   // the title stays short; the count is the selection on screen, and in the tooltip
            let name = app.catalog.name(agent.agent)
            ask.title = String(localized: "Ask \(name)")
            ask.image = app.catalog.icon(agent.agent, size: 14)
            ask.imagePosition = .imageLeading
            ask.toolTip = String(localized: "Ask \(name) about \(Self.rows(picked))")
        }
        detailsChanged()
    }

    /// The chat a run came from, else the one every "send to agent" goes to without asking (`FileActions.agent`).
    var agentToAsk: Session? {
        if case .run(let id) = mode, let sid = record(id)?.session, let ran = app.session(sid), ran.status != .exited {
            return ran
        }
        return FileActions(app).agent(in: address.worktree)
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
