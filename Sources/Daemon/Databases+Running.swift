import Core
import Foundation

// Running a statement: who asks, the trial and the user's Allow for an agent's change, and what's kept of the run.

extension Databases {
    /// Who asks, from the caller (`Sessions.asker`): nil for the user (Kelp's window, a terminal of the user's own);
    /// else the agent's session to ask, nil inside when there's none to ask (a program of kelpd's, one that left).
    func agent(origin: String?) -> String?? {
        guard let origin else { return .none }
        let session = Caller.session(of: origin)
        // A session that can't be read is held to an agent's rules, as the fence holds it.
        if let session, !Caller.typedOrigin(origin),
            Log.store.attempt("whether \(session) is an agent's", { try store.forAnAgent(session) }) == false
        {
            return .none
        }
        return .some(session)
    }

    /// `asker`: the program the call came from (the agent's `kelp db query`): a question it waits on ends with it.
    func query(_ q: DatabaseQuery, origin: String?, asker pid: pid_t? = nil) async throws -> QueryResult {
        let asker = agent(origin: origin), forAgent = asker != nil
        let (wid, name) = (q.worktreeId, q.database)
        // Off the pool: a remote project's are read on its host, and reached through a forwarded port.
        let target = try await offloads.run { [self] in try reach(connection(wid, name, agent: forAgent), wid) }
        let sql: String
        do { sql = try SQLText.single(q.sql, target.database.engine) } catch let failure as DatabaseFailure {
            throw RPCError.invalidParams(failure.message)
        }
        if forAgent, let why = SQLText.pastTheDatabase(sql, target.database.engine) { throw RPCError.refused(why) }
        if forAgent, target.database.production, target.database.engine == .postgres, try await superuser(target) {
            throw RPCError.refused(
                "\(target.database.name) is production, and Kelp reaches it as a superuser, whom a read-only "
                    + "transaction doesn't stop: the user can connect it as a role that only reads (Edit…); until "
                    + "then agents can't use it."
            )
        }
        let id = UUID().uuidString, session = asker ?? nil
        var run = DatabaseRun(
            id: id, database: target.database.name, sql: sql, session: session, at: Date(), state: .done)
        let access = forAgent ? target.database.agentAccess : .free
        do {
            let started = Date()
            // As Settings offers them: settings.json (or an agent's `kelp settings set`) can say anything
            let timeout = min(DatabaseTimes.longestRead, max(1, sessions.settings[SettingKeys.databaseTimeout]))
            guard SQLText.mayTryAsRead(sql, target.database.engine) else { throw DatabaseFailure.change }
            let rows = try await DatabaseEngines.read(target, sql, timeout: timeout, off: offloads)
            return finish(q, &run, rows, started: started, agent: forAgent)
        } catch DatabaseFailure.change {
            switch access {
            case .hidden, .read:
                run.state = .refused
                run.error = "\(target.database.name) is read-only for agents."
                note(q.worktreeId, run)
                let others = try await offloads.run { [self] in
                    try connections(wid).filter { [.ask, .free].contains($0.database.agentAccess) }.map(\.database.name)
                }
                throw RPCError.refused(
                    "\(target.database.name) is read-only for agents: ask the user to run it"
                        + (others.isEmpty ? "." : ", or try it on \(others.joined(separator: " or ")).")
                )
            case .ask:
                // In this catch's body a failure isn't the outer catch's: said here (a server that refuses changes)
                let yes: Bool
                do { yes = try await allowed(q, target, sql, &run, asker: (session, pid)) } catch let failure
                    as DatabaseFailure
                {
                    throw failed(q, &run, failure)
                }
                guard yes else { throw RPCError.refused(run.error ?? "The user didn't allow it.") }
                fallthrough
            case .free:
                let started = Date()
                // What the user allowed is what it may change: the table can have changed while it was asked
                let asked = access == .ask ? run.changed : nil
                do {
                    let rows = try await DatabaseEngines.write(target, sql, allowed: asked, off: offloads)
                    run.state = .done
                    return finish(q, &run, rows, started: started, agent: forAgent)
                } catch let failure as DatabaseFailure { throw failed(q, &run, failure) }
            }
        } catch let failure as DatabaseFailure { throw failed(q, &run, failure) }
    }

    /// Whether Postgres takes the connection's role for a superuser: what a read-only transaction and Kelp's text check
    /// leave open (a server's files, other sessions) is then the server's own.
    private func superuser(_ c: DatabaseConnection) async throws -> Bool {
        do {
            let asked = "SELECT current_setting('is_superuser')"
            return try await DatabaseEngines.read(c, asked, timeout: DatabaseTimes.superuser, off: offloads).rows.first?
                .first == "on"
        } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
    }

    private func finish(
        _ q: DatabaseQuery, _ run: inout DatabaseRun, _ rows: DatabaseRows, started: Date, agent: Bool
    )
        -> QueryResult
    {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        var result = QueryResult(
            id: run.id, columns: rows.columns, rows: rows.rows, total: rows.total, changed: rows.changed, ms: ms)
        // A change allowed after its trial: the rows the trial left (RETURNING) stay its rows, for the tab's marks.
        if result.columns.isEmpty, let tried = self.result(q.worktreeId, run.id), !tried.columns.isEmpty {
            result.columns = tried.columns
            result.rows = tried.rows
            result.total = tried.total
        }
        run.rows = rows.total
        run.changed = rows.changed
        run.ms = ms
        // The user's own reads (a page of a table, a count) keep no rows, nothing reads them again, and go whole
        let kept = agent || rows.changed != nil
        if kept { result = Self.trimmed(result) }
        note(q.worktreeId, run, result: kept ? result : nil)
        var sent = result
        let rows =
            q.limit ?? Int(min(Double(DatabaseEngines.keep), max(0, sessions.settings[SettingKeys.databaseRows])))
        sent.rows = Array(result.rows.prefix(max(0, rows)))
        return sent
    }

    /// A result as it's kept: long cells cut (…), rows past `keptBytes` left out (`total` still counts them).
    static func trimmed(_ result: QueryResult) -> QueryResult {
        var out = result, bytes = 0
        out.rows = []
        for row in result.rows {
            let cut = row.map { cell in
                cell.map {
                    $0.utf8.count > keptCell ? String(decoding: $0.utf8.prefix(keptCell), as: UTF8.self) + "…" : $0
                }
            }
            bytes += cut.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
            guard bytes <= keptBytes else {
                out.cut = true
                break
            }
            out.rows.append(cut)
        }
        return out
    }

    private func failed(_ q: DatabaseQuery, _ run: inout DatabaseRun, _ failure: DatabaseFailure) -> RPCError {
        run.state = .failed
        run.error = failure.message
        note(q.worktreeId, run)
        return RPCError.invalidParams(failure.message)
    }

    /// The change tried and rolled back, then asked on the agent's row: whether the user allowed it. `asker`: the agent's
    /// session, and the program its command runs in.
    private func allowed(
        _ q: DatabaseQuery, _ c: DatabaseConnection, _ sql: String, _ run: inout DatabaseRun,
        asker: (session: String?, pid: pid_t?)
    ) async throws -> Bool {
        let pid = asker.pid
        guard let session = asker.session, let ls = sessions.existing(session) else {
            run.state = .refused
            run.error = "Nobody to ask: a change to \(c.database.name) needs the user's Allow on an agent's row."
            note(q.worktreeId, run)
            return false
        }
        var trial: DatabaseRows?
        do { trial = try await DatabaseEngines.trial(c, sql, off: offloads) } catch DatabaseFailure.failed(
            let why)
        {
            // It can't be tried in a transaction (CREATE INDEX CONCURRENTLY, MySQL's DDL): asked all the same.
            Log.session.info("db trial of \(c.database.name) didn't run: \(why)")
        } catch DatabaseFailure.change {
            throw DatabaseFailure.failed(
                "\(c.database.name) takes no changes: the server or file is read-only (a standby, a file's rights).")
        }
        run.state = .asks
        run.changed = trial?.changed
        note(
            q.worktreeId, run,
            result: trial.map {
                Self.trimmed(
                    QueryResult(
                        id: run.id, columns: $0.columns, rows: $0.rows, total: $0.total, changed: $0.changed, ms: 0))
            })
        let question = Self.question(
            sql, database: c.database.name, changed: trial?.changed, held: DatabaseEngines.holdsAllowed(c))
        ls.askForKelp(question)
        let answer = await sessions.permissions.waitForKelp(
            session, question: question, within: DatabaseQuery.answerWithin, asker: pid)
        ls.kelpAsked(question)
        guard answer == "allow" else {
            run.state = .denied
            run.error =
                switch answer {
                case "deny": "The user denied it."
                case PermissionWaits.askerGone: "The agent's command ended before an answer: it didn't run."
                default: "Nobody answered: it's no longer asked."
                }
            note(q.worktreeId, run)
            return false
        }
        // What agents may do there can have changed while it was asked (read-only, hidden, another address)
        var now: DatabaseInfo.Access?
        do {
            now = try await offloads.run { [self] in
                try connection(q.worktreeId, q.database, agent: true).database.agentAccess
            }
        } catch {
            now = nil   // hidden from agents now, or gone
        }
        guard let now, [.ask, .free].contains(now) else {
            run.state = .refused
            run.error = "\(c.database.name) became read-only for agents while it was asked: it didn't run."
            note(q.worktreeId, run)
            return false
        }
        return true
    }

    /// What the agent's row asks: "Allow changing 1204 rows of orders in app_dev?", the table named so that two asked
    /// one after another read apart. "allow" makes the banner, the Dock and the strip offer Allow / Deny
    /// (`Session.asksPermission`).
    /// `held`: whether the change is held to that many rows (`DatabaseEngines.holdsAllowed`); else the number is only
    /// what its trial changed.
    static func question(_ sql: String, database: String, changed: Int?, held: Bool = true) -> String {
        if let changed, ["UPDATE", "DELETE", "INSERT", "MERGE", "REPLACE"].contains(SQLText.verb(sql)) {
            let rows = "\(changed) \(changed == 1 ? "row" : "rows")"
            let of = table(sql).map { " of \($0)" } ?? ""
            guard held else { return "Allow changing rows\(of) in \(database)? Tried just now, it changed \(rows)." }
            return "Allow changing \(rows)\(of) in \(database)?"
        }
        // The whole statement on one line; one too long to read there says it's cut, and where the rest is
        let code = SQLText.code(sql)
        let whole = code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard whole.count > 160 else { return "Allow \(whole) in \(database)?" }
        let lines = code.split(whereSeparator: \.isNewline).count
        let rest = lines > 1 ? "\(lines) lines" : "\(whole.count) characters"
        return "Allow \(whole.prefix(140))… (\(rest), whole in Databases) in \(database)?"
    }

    /// The table a change names: UPDATE orders, DELETE FROM "orders", INSERT OR REPLACE INTO public.orders.
    static func table(_ sql: String) -> String? {
        let changing =
            #/
            ^(?: UPDATE (?:\s+ONLY)? | DELETE\s+FROM | MERGE\s+INTO
                | (?:INSERT|REPLACE) (?:\s+OR\s+\w+)? (?:\s+IGNORE)? \s+INTO ) \s+
            (?<name> (?:"[^"]+"|`[^`]+`|[^\s(,;."`]+) (?: \. (?:"[^"]+"|`[^`]+`|[^\s(,;."`]+) )* )
            /#.ignoresCase()
        guard let match = SQLText.code(sql).firstMatch(of: changing) else { return nil }
        let name = match.output.name.filter { !"\"`".contains($0) }
        return name.isEmpty ? nil : String(name)
    }

    func schema(_ worktreeId: String, _ name: String, table: String?, agent: Bool) async throws -> DatabaseSchema {
        let target = try await offloads.run { [self] in
            try reach(connection(worktreeId, name, agent: agent), worktreeId)
        }
        do { return try await DatabaseEngines.schema(target, table: table, off: offloads) } catch let failure
            as DatabaseFailure
        {
            throw RPCError.invalidParams(failure.message)
        }
    }
}
