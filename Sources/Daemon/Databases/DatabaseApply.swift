import Core
import Foundation

// The tab's edits saved: all in one transaction.

extension Databases {
    /// Saves the tab's edits on the user's behalf: each statement must be a single statement (SQLText.single), and all
    /// of them run in one transaction (`apply`).
    func apply(_ databaseApply: DatabaseApply) async throws -> QueryResult {
        guard !databaseApply.statements.isEmpty else { throw RPCError.invalidParams("Nothing to save.") }
        let (wid, name) = (databaseApply.worktreeId, databaseApply.database)
        let target = try await offloads.run { [self] in try reach(connection(wid, name, agent: false), wid) }
        let statements: [String]
        do {
            statements = try databaseApply.statements.map { try SQLText.single($0, target.database.engine) }
        } catch let failure
            as DatabaseFailure
        {
            throw RPCError.invalidParams(failure.message)
        }
        let started = Date(), sql = statements.joined(separator: ";\n")
        var run = DatabaseRun(id: UUID().uuidString, database: name, sql: sql, session: nil, at: started, state: .done)
        do {
            let changed = try await applied(target, statements, each: databaseApply.each)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            run.changed = changed
            run.ms = ms
            note(wid, run)
            return QueryResult(id: run.id, columns: [], rows: [], total: 0, changed: changed, ms: ms)
        } catch let failure as DatabaseFailure {
            run.state = .failed
            run.error = failure.message
            note(wid, run)
            throw RPCError.invalidParams(failure.message)
        }
    }
}

extension Databases {
    /// With `each`, the changes are kept only if every statement changed exactly that many rows. Limit: a database
    /// whose runner can't count each statement's rows in one transaction (a client program, DuckDB, Appwrite) runs them
    /// the way `apply` does: statements that find their rows by the values they were checked against (Undo's) still
    /// change nothing where a row changed since, but the other statements are kept.
    func applied(_ target: DatabaseConnection, _ statements: [String], each: Int?) async throws -> Int {
        guard let each else { return try await DatabaseEngines.apply(target, statements, off: offloads) }
        let counts: [Int?]
        do {
            counts = try await DatabaseEngines.batch(
                target, statements, keep: { $0.allSatisfy { $0 == each } }, off: offloads)
        } catch let failure as DatabaseFailure where failure == .noBatch {
            return try await DatabaseEngines.apply(target, statements, off: offloads)
        }
        guard counts.allSatisfy({ $0 == each }) else {
            throw DatabaseFailure.failed(
                "The rows aren't as they were when Kelp read them: something changed them since. Nothing was put back.")
        }
        return counts.compactMap { $0 }.reduce(0, +)
    }
}

extension DatabaseApply: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> QueryResult { try await dbs.apply(self) }
}

extension Methods {
    static let databaseApplyMethods: [any Answered.Type] = [DatabaseApply.self]
}
