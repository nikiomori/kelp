import AppKit
import Core
import DesignKit
import KelpKit

/// Undo This Change… puts an agent's change back from the rows Kelp kept of it (`DatabaseUndo`), after showing what
/// that will run. It works only while the rows are as the change left them; when they changed since, nothing is
/// written over.
extension DatabaseTab {
    func undo(_ run: DatabaseRun) {
        let worktree = address.worktree, name = address.name, engine = engine
        let who = run.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "the agent")
        Task {
            let (read, unread) = await app.tryCall(DatabaseResultRead(worktreeId: worktree, id: run.id))
            let kept = read ?? nil
            if let why = DatabaseUndo.refusal(kept, readFailure: read == nil ? unread ?? "" : nil) {
                return Banner.show(why, style: read == nil ? .error : .info)
            }
            guard let kept, let table = kept.change?.tableName else { return }
            let (now, failure) = await app.tryCall(
                DatabaseQuery(
                    worktreeId: worktree, database: name, sql: DatabaseUndo.check(kept, engine),
                    limit: QueryResult.kept))
            guard let now else {
                return Banner.show(String(localized: "Can’t read \(table) to undo the change: \(failure ?? "")"))
            }
            guard DatabaseUndo.unchanged(kept, now: now.rows) else {
                return Banner.show(
                    String(localized: "The rows of \(table) aren’t as \(who) left them any more: nothing was put back.")
                )
            }
            let statements = DatabaseUndo.statements(kept, engine)
            guard !statements.isEmpty, await confirmed(statements, who: who, table: table, at: run.at) else { return }
            let (done, error) = await app.tryCall(
                DatabaseApply(worktreeId: worktree, database: name, statements: statements, each: 1))
            guard let done else {
                return Banner.show(String(localized: "Nothing was put back: \(error ?? "")"))
            }
            let back = done.changed ?? 0
            guard back == statements.count else {   // some database can't count each one (`Databases.applied`)
                let rows = Self.rows(back).capitalizedFirst
                return Banner.show(
                    String(localized: "\(rows) of \(table) put back: the others changed since Kelp read them."))
            }
            Banner.show(String(localized: "\(Self.rows(back).capitalizedFirst) of \(table) put back."))
            refresh()
        }
    }

    /// Asks the question, showing the first statements the undo would run.
    private func confirmed(_ statements: [String], who: String, table: String, at: Date) async -> Bool {
        let shown = statements.prefix(8).joined(separator: ";\n") + ";"
        let more = statements.count > 8 ? "\n" + String(localized: "… \(statements.count - 8) more") : ""
        let rows = Self.rows(statements.count)
        return await confirm(
            String(localized: "Undo \(who)’s change to \(table)?"),
            detail: String(
                localized: "\(rows.capitalizedFirst) go back to what they were \(shortAgo(at)), in one transaction.")
                + "\n\n" + shown + more,
            action: String(localized: "Undo"))
    }
}
