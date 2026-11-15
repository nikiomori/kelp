import Core
import Foundation

// Several statements in one call (`kelp db query "a; b"`): one change. Tried together and rolled back, asked about once
// where the database asks, then run in one transaction: all of them or none.

extension Databases {
    /// `asker`: nil for the user, else the agent's session to ask; and the program its command runs in.
    func batch(
        _ q: DatabaseQuery, _ c: DatabaseConnection, _ statements: [String], asker: (session: String??, pid: pid_t?)
    ) async throws -> QueryResult {
        let forAgent = asker.session != nil, session = asker.session ?? nil
        let name = c.database.name, engine = c.database.engine
        var run = DatabaseRun(
            id: UUID().uuidString, database: name, sql: statements.joined(separator: ";\n"), session: session,
            at: Date(), state: .done)
        do {
            // MySQL commits its DDL as it runs, and with it whatever came before
            if engine == .mysql, let alone = statements.first(where: { !SQLText.mayTry($0, engine) }) {
                throw DatabaseFailure.failed(
                    "MySQL commits \(SQLText.verb(alone)) as it runs: it can't be one of several in a transaction. "
                        + "Run it on its own.")
            }
            var asked: [Int?]?
            switch forAgent ? c.database.agentAccess : .free {
            case .hidden, .read:
                run.state = .refused
                run.error = "\(name) is read-only for agents."
                note(q.worktreeId, run)
                throw RPCError.refused("\(name) is read-only for agents: ask the user to run it.")
            case .ask:
                guard let ls = whoToAsk(q, c, &run, session) else {
                    throw RPCError.refused(run.error ?? "Nobody to ask.")
                }
                let tried = try await DatabaseEngines.batch(c, statements, keep: { _ in false }, off: offloads)
                run.state = .asks
                run.changed = Self.total(tried)
                note(q.worktreeId, run, result: Self.result(run.id, statements, tried, ms: 0))
                let question = Self.question(statements: statements.count, database: name, changed: run.changed)
                guard await answered(q, &run, ls, question, asker: (session, asker.pid)) else {
                    throw RPCError.refused(run.error ?? "The user didn't allow it.")
                }
                asked = tried
            case .free: break
            }
            let started = Date(), allowed = asked
            // What the user allowed is what it may change: the tables can have changed while it was asked
            let changed = try await DatabaseEngines.batch(
                c, statements, keep: { allowed == nil || $0 == allowed }, off: offloads)
            if let allowed, changed != allowed {
                throw DatabaseEngines.notAsAllowed(Self.total(changed), Self.total(allowed) ?? 0)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            run.state = .done
            run.changed = Self.total(changed)
            run.ms = ms
            let result = Self.result(run.id, statements, changed, ms: ms)
            note(q.worktreeId, run, result: result)
            return result
        } catch let failure as DatabaseFailure { throw failed(q, &run, failure) }
    }

    /// The rows they changed in all; nil when none of them says (reads only).
    static func total(_ changed: [Int?]) -> Int? {
        let said = changed.compactMap { $0 }
        return said.isEmpty ? nil : said.reduce(0, +)
    }

    private static func result(_ id: String, _ statements: [String], _ changed: [Int?], ms: Int) -> QueryResult {
        var result = QueryResult(id: id, columns: [], rows: [], total: 0, changed: total(changed), ms: ms)
        result.statements = zip(statements, changed).map { StatementResult(sql: $0, changed: $1) }
        return result
    }

    /// "Allow 3 statements changing 40 rows in app_dev?": one question for them all.
    static func question(statements: Int, database: String, changed: Int?) -> String {
        guard let changed else { return "Allow \(statements) statements in \(database)?" }
        return "Allow \(statements) statements changing \(changed) \(changed == 1 ? "row" : "rows") in \(database)?"
    }
}
