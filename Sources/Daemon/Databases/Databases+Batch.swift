import Core
import Foundation

// Several statements sent in one call (`kelp db query "a; b"`) run as one change. They are tried together and rolled
// back, the user is asked once when the database asks before changes, and then they run in one transaction, so all of
// them are kept or none.

extension Databases {
    /// Runs the statements as one change. `asker.session` is nil when the user runs them and otherwise holds the
    /// agent's session to ask. `asker.pid` is the program the agent's command runs in.
    func batch(
        _ databaseQuery: DatabaseQuery, _ databaseConnection: DatabaseConnection, _ statements: [String],
        asker: (session: String??, pid: pid_t?)
    ) async throws -> QueryResult {
        let forAgent = asker.session != nil, session = asker.session ?? nil
        let name = databaseConnection.database.name, engine = databaseConnection.database.engine
        var run = DatabaseRun(
            id: UUID().uuidString, database: name, sql: statements.joined(separator: ";\n"), session: session,
            at: Date(), state: .done)
        do {
            // MySQL commits a DDL statement as it runs it, and every statement before it too
            if engine == .mysql, let alone = statements.first(where: { !SQLText.mayTry($0, engine) }) {
                throw DatabaseFailure.failed(
                    "MySQL commits \(SQLText.verb(alone)) as it runs: it can't be one of several in a transaction. "
                        + "Run it on its own.")
            }
            var asked: [Int?]?
            switch forAgent ? databaseConnection.database.agentAccess : .free {
            case .hidden, .read:
                run.state = .refused
                run.error = "\(name) is read-only for agents."
                note(databaseQuery.worktreeId, run)
                throw RPCError.refused("\(name) is read-only for agents: ask the user to run it.")
            case .ask:
                guard let ls = whoToAsk(databaseQuery, databaseConnection, &run, session) else {
                    throw RPCError.refused(run.error ?? "Nobody to ask.")
                }
                let tried = try await DatabaseEngines.batch(
                    databaseConnection, statements, keep: { _ in false }, off: offloads)
                run.state = .asks
                run.changed = Self.total(tried)
                note(databaseQuery.worktreeId, run, result: Self.result(run.id, statements, tried, ms: 0))
                let question = Self.question(statements: statements.count, database: name, changed: run.changed)
                guard await answered(databaseQuery, &run, ls, question, asker: (session, asker.pid)) else {
                    throw RPCError.refused(run.error ?? "The user didn't allow it.")
                }
                asked = tried
            case .free: break
            }
            let started = Date(), allowed = asked
            // The batch may change only the counts the user allowed, because the tables can change while asking
            let changed = try await DatabaseEngines.batch(
                databaseConnection, statements, keep: { allowed == nil || $0 == allowed }, off: offloads)
            if let allowed, changed != allowed {
                throw DatabaseEngines.notAsAllowed(Self.total(changed), Self.total(allowed) ?? 0)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            run.state = .done
            run.changed = Self.total(changed)
            run.ms = ms
            let result = Self.result(run.id, statements, changed, ms: ms)
            note(databaseQuery.worktreeId, run, result: result)
            return result
        } catch let failure as DatabaseFailure { throw failed(databaseQuery, &run, failure) }
    }

    /// The total number of rows the statements changed, or nil when no statement reports a count (reads only).
    static func total(_ changed: [Int?]) -> Int? {
        let said = changed.compactMap { $0 }
        return said.isEmpty ? nil : said.reduce(0, +)
    }

    private static func result(_ id: String, _ statements: [String], _ changed: [Int?], ms: Int) -> QueryResult {
        var result = QueryResult(id: id, columns: [], rows: [], total: 0, changed: total(changed), ms: ms)
        result.statements = zip(statements, changed).map { StatementResult(sql: $0, changed: $1) }
        return result
    }

    /// The one question asked for all the statements, such as "Allow 3 statements changing 40 rows in app_dev?".
    static func question(statements: Int, database: String, changed: Int?) -> String {
        guard let changed else { return "Allow \(statements) statements in \(database)?" }
        return "Allow \(statements) statements changing \(changed) \(changed == 1 ? "row" : "rows") in \(database)?"
    }
}
