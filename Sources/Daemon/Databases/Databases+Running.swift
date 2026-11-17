import Core
import Foundation

// Running a statement: who asks, the trial and the user's Allow for an agent's change, and what's kept of the run.

extension Databases {
    /// Who asks (`Store.agent(origin:)`): nil for the user, else the agent's session to ask.
    func agent(origin: String?) -> String?? { store.agent(origin: origin) }

    /// `asker`: the program the call came from (the agent's `kelp db query`): a question it waits on ends with it.
    func query(_ databaseQuery: DatabaseQuery, origin: String?, asker pid: pid_t? = nil) async throws -> QueryResult {
        let asker = agent(origin: origin), forAgent = asker != nil
        let (wid, name) = (databaseQuery.worktreeId, databaseQuery.database)
        // Off the pool: a remote project's are read on its host, and reached through a forwarded port.
        let target = try await offloads.run { [self] in try reach(connection(wid, name, agent: forAgent), wid) }
        let all: [String]
        do { all = try SQLText.several(databaseQuery.sql, target.database.engine) } catch let failure as DatabaseFailure
        {
            throw RPCError.invalidParams(failure.message)
        }
        if forAgent, let why = all.lazy.compactMap({ SQLText.pastTheDatabase($0, target.database.engine) }).first {
            throw RPCError.refused(why)
        }
        if forAgent, target.database.production, target.database.engine == .postgres, try await superuser(target) {
            throw RPCError.refused(
                "\(target.database.name) is production, and Kelp reaches it as a superuser, whom a read-only "
                    + "transaction doesn't stop: the user can connect it as a role that only reads (Edit…); until "
                    + "then agents can't use it."
            )
        }
        // Several statements are one change: tried, asked about and run together (`batch`)
        guard all.count == 1 else { return try await batch(databaseQuery, target, all, asker: (asker, pid)) }
        let id = UUID().uuidString, session = asker ?? nil, sql = all[0]
        var run = DatabaseRun(
            id: id, database: target.database.name, sql: sql, session: session, at: Date(), state: .done)
        let access = forAgent ? target.database.agentAccess : .free
        do {
            let started = Date()
            // As Settings offers them: settings.json (or an agent's `kelp settings set`) can say anything
            let timeout = min(DatabaseTimes.longestRead, max(1, settings[SettingKeys.databaseTimeout]))
            guard SQLText.mayTryAsRead(sql, target.database.engine) else { throw DatabaseFailure.change }
            let rows = try await DatabaseEngines.read(target, sql, timeout: timeout, off: offloads)
            return finish(databaseQuery, &run, rows, started: started, agent: forAgent)
        } catch DatabaseFailure.change {
            switch access {
            case .hidden, .read:
                run.state = .refused
                run.error = "\(target.database.name) is read-only for agents."
                note(databaseQuery.worktreeId, run)
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
                do { yes = try await allowed(databaseQuery, target, sql, &run, asker: (session, pid)) } catch let
                    failure
                    as DatabaseFailure
                {
                    throw failed(databaseQuery, &run, failure)
                }
                guard yes else { throw RPCError.refused(run.error ?? "The user didn't allow it.") }
                fallthrough
            case .free:
                // An agent's change that asks nobody is tried first too: what it does to its rows is kept with it
                let tried = access == .ask ? result(wid, id) : forAgent ? await triedFirst(target, sql, id) : nil
                let started = Date()
                // What the user allowed is what it may change: the table can have changed while it was asked
                let asked = access == .ask ? run.changed : nil
                do {
                    let saying = Self.saying(sql, target.database.engine, tried: tried)
                    let rows = try await DatabaseEngines.write(target, saying, allowed: asked, off: offloads)
                    run.state = .done
                    return finish(databaseQuery, &run, rows, started: started, agent: forAgent, tried: tried)
                } catch let failure as DatabaseFailure { throw failed(databaseQuery, &run, failure) }
            }
        } catch let failure as DatabaseFailure { throw failed(databaseQuery, &run, failure) }
    }

    /// Whether Postgres takes the connection's role for a superuser: what a read-only transaction and Kelp's text check
    /// leave open (a server's files, other sessions) is then the server's own.
    private func superuser(_ databaseConnection: DatabaseConnection) async throws -> Bool {
        do {
            let asked = "SELECT current_setting('is_superuser')"
            return try await DatabaseEngines.read(
                databaseConnection, asked, timeout: DatabaseTimes.superuser, off: offloads
            ).rows.first?
            .first == "on"
        } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
    }

    /// A row change by an agent on a database that asks nobody, tried and rolled back before it runs: its rows with
    /// what it does to them (`rowChange`); nil when it can't be tried or isn't one table's rows.
    /// Limit: the change runs twice (once rolled back), for the rows as they were.
    private func triedFirst(_ databaseConnection: DatabaseConnection, _ sql: String, _ id: String) async -> QueryResult?
    {
        guard Self.kind(sql, databaseConnection.database.engine) != nil else { return nil }
        do {
            let tried = try await DatabaseEngines.trial(databaseConnection, sql, off: offloads)
            guard let change = await rowChange(databaseConnection, sql, tried) else { return nil }
            return Self.kept(tried, id: id, change: change)
        } catch {
            return nil   // the change itself says what's wrong with it
        }
    }

    /// `tried`: the change's trial, as it was kept.
    private func finish(
        _ databaseQuery: DatabaseQuery, _ run: inout DatabaseRun, _ rows: DatabaseRows, started: Date, agent: Bool,
        tried: QueryResult? = nil
    )
        -> QueryResult
    {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        var result = QueryResult(
            id: run.id, columns: rows.columns, rows: rows.rows, total: rows.total, changed: rows.changed, ms: ms)
        run.rows = rows.total
        run.changed = rows.changed
        run.ms = ms
        // The user's own reads (a page of a table, a count) keep no rows, nothing reads them again, and go whole
        let kept = agent || rows.changed != nil
        // A change after its trial: its rows are the ones it wrote itself (`saying`), never the trial's, and with
        // them goes what the trial said it does to them (`written`), for the tab's marks and Undo.
        if kept { result = Self.kept(rows, id: run.id, change: tried.flatMap { Self.written($0, rows) }, ms: ms) }
        note(databaseQuery.worktreeId, run, result: kept ? result : nil)
        var sent = result
        let rows =
            databaseQuery.limit
            ?? Int(min(Double(DatabaseEngines.keep), max(0, settings[SettingKeys.databaseRows])))
        sent.rows = Array(result.rows.prefix(max(0, rows)))
        sent.change = nil   // the user's to see and undo: an agent has its rows
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

    func failed(_ databaseQuery: DatabaseQuery, _ run: inout DatabaseRun, _ failure: DatabaseFailure) -> RPCError {
        run.state = .failed
        run.error = failure.message
        note(databaseQuery.worktreeId, run)
        return RPCError.invalidParams(failure.message)
    }

    /// The change tried and rolled back, then asked on the agent's row: whether the user allowed it. `asker`: the agent's
    /// session, and the program its command runs in.
    private func allowed(
        _ databaseQuery: DatabaseQuery, _ databaseConnection: DatabaseConnection, _ sql: String,
        _ run: inout DatabaseRun,
        asker: (session: String?, pid: pid_t?)
    ) async throws -> Bool {
        guard let ls = whoToAsk(databaseQuery, databaseConnection, &run, asker.session) else { return false }
        var trial: DatabaseRows?
        do {
            trial = try await DatabaseEngines.trial(databaseConnection, sql, off: offloads)
        } catch DatabaseFailure.failed(
            let why)
        {
            // It can't be tried in a transaction (CREATE INDEX CONCURRENTLY, MySQL's DDL): asked all the same.
            Log.session.info("db trial of \(databaseConnection.database.name) didn't run: \(why)")
        } catch DatabaseFailure.change {
            throw DatabaseFailure.failed(
                "\(databaseConnection.database.name) takes no changes: the server or file is read-only "
                    + "(a standby, a file's rights)."
            )
        }
        var change: RowChange?
        if let trial { change = await rowChange(databaseConnection, sql, trial) }
        run.state = .asks
        run.changed = trial?.changed
        note(databaseQuery.worktreeId, run, result: trial.map { Self.kept($0, id: run.id, change: change) })
        let question = Self.question(
            sql, database: databaseConnection.database.name, changed: trial?.changed,
            held: DatabaseEngines.runner(databaseConnection, off: offloads).holdsAllowed)
        return await answered(databaseQuery, &run, ls, question, asker: asker)
    }

    /// The agent's session a change is asked on; nil (and the run refused) when there's none to ask.
    func whoToAsk(
        _ databaseQuery: DatabaseQuery, _ databaseConnection: DatabaseConnection, _ run: inout DatabaseRun,
        _ session: String?
    )
        -> LiveSession?
    {
        guard let session, let ls = live[session] else {
            run.state = .refused
            run.error =
                "Nobody to ask: a change to \(databaseConnection.database.name) needs the user's Allow on an "
                + "agent's row."
            note(databaseQuery.worktreeId, run)
            return nil
        }
        return ls
    }

    /// `question` asked on the agent's row and waited for: whether the user allowed it, and agents may still change
    /// the database. `asker`: the agent's session, and the program its command runs in.
    func answered(
        _ databaseQuery: DatabaseQuery, _ run: inout DatabaseRun, _ ls: LiveSession, _ question: String,
        asker: (session: String?, pid: pid_t?)
    ) async -> Bool {
        ls.askForKelp(question)
        let answer = await permissions.waitForKelp(
            asker.session ?? "", question: question, within: DatabaseQuery.answerWithin, asker: asker.pid)
        ls.kelpAsked(question)
        guard answer == "allow" else {
            run.state = .denied
            run.error =
                switch answer {
                case "deny": "The user denied it."
                case PermissionWaits.askerGone: "The agent's command ended before an answer: it didn't run."
                default: "Nobody answered: it's no longer asked."
                }
            note(databaseQuery.worktreeId, run)
            return false
        }
        // What agents may do there can have changed while it was asked (read-only, hidden, another address)
        var now: DatabaseInfo.Access?
        do {
            now = try await offloads.run { [self] in
                try connection(databaseQuery.worktreeId, databaseQuery.database, agent: true).database.agentAccess
            }
        } catch {
            now = nil   // hidden from agents now, or gone
        }
        guard let now, [.ask, .free].contains(now) else {
            run.state = .refused
            run.error = "\(run.database) became read-only for agents while it was asked: it didn't run."
            note(databaseQuery.worktreeId, run)
            return false
        }
        return true
    }

    /// What the agent's row asks: "Allow changing 1204 rows of orders in app_dev?", the table named so that two asked
    /// one after another read apart. "allow" makes the banner, the Dock and the strip offer Allow / Deny
    /// (`Session.asksPermission`).
    /// `held`: whether the change is held to that many rows (`DatabaseRunner.holdsAllowed`); else the number is only
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
    /// `asWritten`: with its quotes, to go into SQL as the statement has it.
    static func table(_ sql: String, asWritten: Bool = false) -> String? {
        let changing =
            #/
            ^(?: UPDATE (?:\s+ONLY)? | DELETE\s+FROM | MERGE\s+INTO
                | (?:INSERT|REPLACE) (?:\s+OR\s+\w+)? (?:\s+IGNORE)? \s+INTO ) \s+
            (?<name> (?:"[^"]+"|`[^`]+`|[^\s(,;."`]+) (?: \. (?:"[^"]+"|`[^`]+`|[^\s(,;."`]+) )* )
            /#.ignoresCase()
        guard let match = SQLText.code(sql).firstMatch(of: changing) else { return nil }
        let name = asWritten ? String(match.output.name) : String(match.output.name.filter { !"\"`".contains($0) })
        return name.isEmpty ? nil : name
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
