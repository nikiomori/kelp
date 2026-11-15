import AppKit
import Core
import DesignKit
import KelpKit

/// Undo This Change…: an agent's change put back from the rows Kelp kept of it (`DatabaseUndo`), after a look at what
/// that runs. Only while the rows are as the change left them: changed since, nothing is written over.
extension DatabaseTab {
    func undo(_ run: DatabaseRun) {
        let worktree = address.worktree, name = address.name, engine = engine
        let who = run.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "the agent")
        Task {
            let kept = await app.quiet(DatabaseResultRead(worktreeId: worktree, id: run.id)) ?? nil
            if let why = DatabaseUndo.refusal(kept) { return Banner.show(why) }
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
                DatabaseApply(worktreeId: worktree, database: name, statements: statements))
            guard let done else {
                return Banner.show(String(localized: "Nothing was put back: \(error ?? "")"))
            }
            Banner.show(String(localized: "\(Self.rows(done.changed ?? 0).capitalizedFirst) of \(table) put back."))
            refresh()
        }
    }

    /// The question, with the first statements it would run.
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
