import Core
import Foundation

/// Compares a branch's copy with the database it copies (`db.diff`): the tables' columns, and their rows counted in
/// each. Both are read as the caller may read them, so an agent compares no database hidden from it.
extension Databases {
    func compare(_ worktreeId: String, _ name: String?, agent: Bool) async throws -> DatabaseComparison {
        let (copy, original) = try await offloads.run { [self] in try pair(worktreeId, name, agent: agent) }
        let branch = try await offloads.run { [self] in try store.worktree(worktreeId)?.branch ?? "" }
        async let mine = tables(copy, worktreeId), theirs = tables(original, worktreeId)
        let (now, was) = try await (mine, theirs)
        return DatabaseComparison(
            copy: copy.database.name, original: original.database.name, branch: branch,
            tables: Self.compared(now, was))
    }

    /// The copy named (or the workspace's only copy) and the database it copies. A file copied into the branch's
    /// folder keeps the original's name, so then the original is the project's own workspace's.
    private func pair(_ worktreeId: String, _ name: String?, agent: Bool) throws -> (
        DatabaseConnection,
        DatabaseConnection
    ) {
        let copies = try connections(worktreeId).filter {
            $0.database.copy != nil && (!agent || $0.database.agentAccess != .hidden)
        }
        guard let named = name ?? (copies.count == 1 ? copies[0].database.name : nil) else {
            throw RPCError.invalidParams(
                copies.isEmpty
                    ? "This branch has no copy of a database: Copy for <branch> in Databases makes one."
                    : "Which copy? kelp db diff " + copies.map(\.database.name).joined(separator: " | "))
        }
        let copy = try connection(worktreeId, named, agent: agent)
        guard let of = copy.database.copy?.of else {
            throw RPCError.invalidParams("\(named) isn't a branch's copy of a database: kelp db list says which are.")
        }
        if of != named { return (copy, try connection(worktreeId, of, agent: agent)) }
        let worktree = try store.worktree(worktreeId)
        let project = try worktree.flatMap { try store.repo($0.repoId)?.path }
        guard let home = try store.worktrees(repo: worktree?.repoId).first(where: { $0.path == project }) else {
            throw RPCError.invalidParams("The project's own folder isn't open in Kelp, where \(of) is.")
        }
        return (copy, try connection(home.id, of, agent: agent))
    }

    /// A database's tables (views left out), with their rows counted in one statement (`counting`). Where counting
    /// fails, the schema's own numbers stand.
    private func tables(_ databaseConnection: DatabaseConnection, _ worktreeId: String) async throws
        -> [DatabaseSchema.Table]
    {
        let near = try await offloads.run { [self] in try reach(databaseConnection, worktreeId) }
        var tables: [DatabaseSchema.Table]
        do {
            tables = try await DatabaseEngines.schema(near, table: nil, off: offloads).tables.filter { $0.kind == nil }
        } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
        guard let sql = Self.counting(tables, near.database) else { return tables }
        do {
            var counts: [String: Int] = [:]
            for row in try await DatabaseEngines.read(near, sql, off: offloads).rows where row.count == 2 {
                if let name = row[0], let count = row[1].flatMap({ Int($0) }) { counts[name] = count }
            }
            for i in tables.indices { tables[i].rows = counts[tables[i].name] }
        } catch {
            Log.store.error("counting \(near.database.name)'s rows: \(error)")
        }
        return tables
    }

    /// The read that counts each table's rows, or nil when none is counted: a production database keeps the schema's
    /// own numbers (Postgres' estimates), as an exact COUNT(*) of each table would read all of it.
    static func counting(_ tables: [DatabaseSchema.Table], _ db: DatabaseInfo) -> String? {
        guard !tables.isEmpty, !db.production else { return nil }
        return tables.map { "SELECT \(db.engine.literal($0.name)), COUNT(*) FROM \(db.engine.table($0.name))" }
            .joined(separator: " UNION ALL ")
    }

    /// The tables of both, by name: what is only in one, and the columns that differ in those in both.
    static func compared(_ now: [DatabaseSchema.Table], _ was: [DatabaseSchema.Table])
        -> [DatabaseComparison.Table]
    {
        let before = Dictionary(was.map { ($0.name, $0) }) { a, _ in a }
        let after = Dictionary(now.map { ($0.name, $0) }) { a, _ in a }
        let names = Set(before.keys).union(after.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.map { name in
            guard let mine = after[name] else { return .init(name: name, change: .dropped, was: before[name]?.rows) }
            guard let theirs = before[name] else { return .init(name: name, change: .added, rows: mine.rows) }
            let columns = Self.columns(mine.columns, theirs.columns)
            return .init(
                name: name, change: columns.isEmpty ? .same : .changed, columns: columns, rows: mine.rows,
                was: theirs.rows)
        }
    }

    /// "+ paid_at TEXT" for a column only the copy has, "− note TEXT" for one it lost, "total INTEGER → REAL" for one
    /// whose type changed.
    static func columns(_ now: [DatabaseSchema.Column], _ was: [DatabaseSchema.Column]) -> [String] {
        let before = Dictionary(was.map { ($0.name, $0.type) }) { a, _ in a }
        let names = Set(now.map(\.name))
        let changed = now.compactMap { column -> String? in
            guard let type = before[column.name] else { return "+ \(column.name) \(column.type)" }
            return type == column.type ? nil : "\(column.name) \(type) → \(column.type)"
        }
        return changed + was.filter { !names.contains($0.name) }.map { "− \($0.name) \($0.type)" }
    }
}

extension DatabaseDiff: AsyncHandled {
    static let agents = AgentAccess.acts
    func handle(_ dbs: Databases) async throws -> DatabaseComparison {
        try await dbs.compare(worktreeId, database, agent: dbs.agent(origin: Sessions.asker) != nil)
    }
}
