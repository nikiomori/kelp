import Core
import Foundation

// Running a statement: who is asking, the trial run and the user's Allow for an agent's change, and what Kelp keeps of
// the run.

extension Databases {
    /// Returns who is asking (`Store.agent(origin:)`): nil for the user, and otherwise the agent's session to ask.
    func agent(origin: String?) -> String?? { store.agent(origin: origin) }

    /// Runs a statement for the user or an agent. `asker` is the program the call came from (the agent's
    /// `kelp db query`), and a question that program waits on ends when the program ends.
    func query(_ databaseQuery: DatabaseQuery, origin: String?, asker pid: pid_t? = nil) async throws -> QueryResult {
        let asker = agent(origin: origin), forAgent = asker != nil
        let (wid, name) = (databaseQuery.worktreeId, databaseQuery.database)
        // This runs off the pool, because a remote project's databases are read on its host and reached through a
        // forwarded port.
        let target = try await offloads.run { [self] in try reach(connection(wid, name, agent: forAgent), wid) }
        if forAgent, target.database.agentAccess == .structure {
            throw RPCError.refused(
                "\(name) shows agents its structure only: `kelp db schema` reads its tables, columns and row counts, "
                    + "but no statement runs on it for agents. Write the query and ask the user to run it, or to let "
                    + "agents read it.")
        }
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
        // Several statements make one change, so they are tried, asked about and run together (`batch`)
        guard all.count == 1 else { return try await batch(databaseQuery, target, all, asker: (asker, pid)) }
        let id = UUID().uuidString, session = asker ?? nil, sql = all[0]
        var run = DatabaseRun(
            id: id, database: target.database.name, sql: sql, session: session, at: Date(), state: .done)
        let access = forAgent ? target.database.agentAccess : .free
        do {
            let started = Date()
            // Keep to the range Settings offers, because settings.json (or an agent's `kelp settings set`) can hold
            // any value
            let timeout = min(DatabaseTimes.longestRead, max(1, settings[SettingKeys.databaseTimeout]))
            guard SQLText.mayTryAsRead(sql, target.database.engine) else { throw DatabaseFailure.change }
            let rows = try await DatabaseEngines.read(target, sql, timeout: timeout, off: offloads)
            return finish(databaseQuery, &run, rows, started: started, agent: forAgent)
        } catch DatabaseFailure.change {
            switch access {
            case .hidden, .structure, .read:
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
                // A failure in this catch's body isn't caught by the outer catch, so it is reported here (a server that
                // refuses changes)
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
                // An agent's change on a database that asks nobody is tried first too, so what it does to its rows is
                // kept with it
                let tried = access == .ask ? result(wid, id) : forAgent ? await triedFirst(target, sql, id) : nil
                let started = Date()
                // The change may touch only the number of rows the user allowed, because the table can change while
                // the user is asked. A change whose count isn't its rows' (`changesUncounted`) is still held to the
                // count its trial reported, so a different one isn't committed.
                let asked = access == .ask ? tried?.changed ?? run.changed : nil
                await turnChanging(session, target, wid)   // a branch's Postgres copy is kept for Undo Turn
                do {
                    let saying = Self.saying(sql, target.database.engine, tried: tried)
                    let rows = try await DatabaseEngines.write(target, saying, allowed: asked, off: offloads)
                    run.state = .done
                    let sent = finish(databaseQuery, &run, rows, started: started, agent: forAgent, tried: tried)
                    await turnChanged(run)
                    return sent
                } catch let failure as DatabaseFailure { throw failed(databaseQuery, &run, failure) }
            }
        } catch let failure as DatabaseFailure { throw failed(databaseQuery, &run, failure) }
    }

    /// Whether Postgres treats the connection's role as a superuser. If it does, what a read-only transaction and
    /// Kelp's text check leave open (the server's files, other sessions) is guarded by the server alone.
    private func superuser(_ databaseConnection: DatabaseConnection) async throws -> Bool {
        do {
            let asked = "SELECT current_setting('is_superuser')"
            return try await DatabaseEngines.read(
                databaseConnection, asked, timeout: DatabaseTimes.superuser, off: offloads
            ).rows.first?
            .first == "on"
        } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
    }

    /// Tries an agent's row change on a database that asks nobody, and rolls it back, before the change really runs.
    /// Returns its rows with what it does to them (`rowChange`), or nil when it can't be tried or doesn't change one
    /// table's rows.
    /// Limit: the change runs twice (once rolled back), for the rows as they were.
    private func triedFirst(_ databaseConnection: DatabaseConnection, _ sql: String, _ id: String) async -> QueryResult?
    {
        guard Self.kind(sql, databaseConnection.database.engine) != nil else { return nil }
        do {
            let tried = try await DatabaseEngines.trial(databaseConnection, sql, off: offloads)
            guard let change = await rowChange(databaseConnection, sql, tried) else { return nil }
            return Self.kept(tried, id: id, change: change)
        } catch {
            return nil   // the real run of the change reports what's wrong with it
        }
    }

    /// Records the finished run and returns what the caller is sent. `tried` is the change's trial, as it was kept.
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
        // The user's own reads (a page of a table, a count) keep no rows, because nothing reads them again, and they
        // are sent whole
        let kept = agent || rows.changed != nil
        // For a change after its trial, the kept rows are the ones the change itself returned (`saying`), never the
        // trial's. They come with what the trial said the change does to them (`written`), for the marks in the tab
        // and for Undo.
        if kept { result = Self.kept(rows, id: run.id, change: tried.flatMap { Self.written($0, rows) }, ms: ms) }
        note(databaseQuery.worktreeId, run, result: kept ? result : nil)
        var sent = result
        let rows =
            databaseQuery.limit
            ?? Int(min(Double(DatabaseEngines.keep), max(0, settings[SettingKeys.databaseRows])))
        sent.rows = Array(result.rows.prefix(max(0, rows)))
        sent.change = nil   // the change is for the user to see and undo; an agent gets only the rows
        return sent
    }

    /// Returns a result as Kelp keeps it. Long cells are cut (…), and rows past `keptBytes` are left out (`total`
    /// still counts them).
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
        // A statement the user stopped fails however its engine ended it (a closed connection, a killed client)
        run.error = DatabaseStop.current.flatMap { $0.stopped ? $0.said : nil } ?? failure.message
        note(databaseQuery.worktreeId, run)
        return RPCError.invalidParams(run.error ?? failure.message)
    }

    /// Tries the change and rolls it back, then asks the user on the agent's row. Returns whether the user allowed it.
    /// `asker` is the agent's session and the program its command runs in.
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
            // Some changes can't be tried in a transaction (CREATE INDEX CONCURRENTLY, MySQL's DDL). The user is
            // asked all the same.
            Log.session.info("db trial of \(databaseConnection.database.name) didn't run: \(why)")
        } catch DatabaseFailure.change {
            throw DatabaseFailure.failed(
                "\(databaseConnection.database.name) takes no changes: the server or file is read-only "
                    + "(a standby, a file's rights)."
            )
        }
        var change: RowChange?, kept: QueryResult?
        if let trial {
            change = await rowChange(databaseConnection, sql, trial)
            kept = Self.kept(trial, id: run.id, change: change)
            let risk = await risk(databaseConnection, sql, change: kept?.change)
            kept?.risk = risk
        }
        run.state = .asks
        // Only a row change's count is the rows that would change: a DDL's 0 or a WITH's selected rows isn't
        run.changed = SQLText.countsItsRows(sql) ? trial?.changed : nil
        note(databaseQuery.worktreeId, run, result: kept)
        let question = Self.question(
            sql, database: databaseConnection.database.name, changed: trial?.changed,
            held: DatabaseEngines.runner(databaseConnection, off: offloads).holdsAllowed)
        return await answered(databaseQuery, &run, ls, question, asker: asker)
    }

    /// Returns the agent's session to ask about a change. Returns nil, and marks the run refused, when there's no
    /// session to ask.
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

    /// Asks `question` on the agent's row and waits for the answer. Returns true when the user allowed it and agents
    /// may still change the database. `asker` is the agent's session and the program its command runs in.
    func answered(
        _ databaseQuery: DatabaseQuery, _ run: inout DatabaseRun, _ ls: LiveSession, _ question: String,
        asker: (session: String?, pid: pid_t?)
    ) async -> Bool {
        ls.askForKelp(question)
        let answer = await permissions.waitForKelp(
            asker.session ?? "", question: question, within: DatabaseQuery.answerWithin, asker: asker.pid, run: run.id)
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
        // What agents may do on the database can change while the user is asked (read-only, hidden, another address)
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

    /// The question the agent's row asks, such as "Allow changing 1204 rows of orders in app_dev?". It names the table
    /// so that two questions asked one after another read apart. The word "allow" makes the banner, the Dock and the
    /// strip offer Allow / Deny (`Session.asksPermission`).
    /// `held` says whether the change is held to that many rows (`DatabaseRunner.holdsAllowed`). When it isn't, the
    /// question says the number is only what the trial changed.
    static func question(_ sql: String, database: String, changed: Int?, held: Bool = true) -> String {
        if let changed, SQLText.countsItsRows(sql) {
            let rows = "\(changed) \(changed == 1 ? "row" : "rows")"
            let of = table(sql).map { " of \($0)" } ?? ""
            guard held else { return "Allow changing rows\(of) in \(database)? Tried just now, it changed \(rows)." }
            return "Allow changing \(rows)\(of) in \(database)?"
        }
        // Show the whole statement on one line. A statement too long to read there says it's cut, and where the rest is
        let code = SQLText.code(sql)
        let whole = code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let uncounted = SQLText.changesUncounted(sql) ? " Kelp can’t count the rows it changes." : ""
        guard whole.count > 160 else { return "Allow \(whole) in \(database)?" + uncounted }
        let lines = code.split(whereSeparator: \.isNewline).count
        let rest = lines > 1 ? "\(lines) lines" : "\(whole.count) characters"
        return "Allow \(whole.prefix(140))… (\(rest), whole in Databases) in \(database)?" + uncounted
    }

    /// Returns the table a change names, as in UPDATE orders, DELETE FROM "orders" or INSERT OR REPLACE INTO
    /// public.orders. With `asWritten`, the name keeps its quotes, so it can go into SQL as the statement has it.
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
        do {
            let schema = try await DatabaseEngines.schema(target, table: table, off: offloads)
            // An agent that sees only the structure isn't shown the migrations table's rows
            let rows = !agent || target.database.agentAccess != .structure
            return table == nil && rows ? await withMigrations(schema, target, worktreeId) : schema
        } catch let failure as DatabaseFailure {
            throw RPCError.invalidParams(failure.message)
        }
    }
}
