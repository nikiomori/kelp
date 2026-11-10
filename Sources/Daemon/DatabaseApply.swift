import Core
import Foundation

// The tab's edits saved: all in one transaction.

extension Databases {
    /// The tab's edits, as the user's: each statement one (SQLText.single), all in one transaction (`apply`).
    func apply(_ q: DatabaseApply) async throws -> QueryResult {
        guard !q.statements.isEmpty else { throw RPCError.invalidParams("Nothing to save.") }
        let (wid, name) = (q.worktreeId, q.database)
        let target = try await offloads.run { [self] in try reach(connection(wid, name, agent: false), wid) }
        let statements: [String]
        do { statements = try q.statements.map { try SQLText.single($0, target.database.engine) } } catch let failure
            as DatabaseFailure
        {
            throw RPCError.invalidParams(failure.message)
        }
        let started = Date(), sql = statements.joined(separator: ";\n")
        var run = DatabaseRun(id: UUID().uuidString, database: name, sql: sql, session: nil, at: started, state: .done)
        do {
            let changed = try await DatabaseEngines.apply(target, statements, off: offloads)
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

extension DatabaseApply: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> QueryResult { try await dbs.apply(self) }
}

extension Methods {
    static let databaseApplyMethods: [any Answered.Type] = [DatabaseApply.self]
}
