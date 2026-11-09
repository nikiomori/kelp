import Core
import Foundation
import GRDB
import os

/// SQLite persistence for repos, worktrees, sessions and diff comments.
public final class Store: Sendable {
    /// A pool on disk: reads run beside a write (WAL) instead of queueing behind it, and many come from the cooperative
    /// pool and connection reader threads, where waiting on a status write's fsync would hold up keystrokes. A queue in
    /// memory (tests: a pool needs a file).
    public let db: any DatabaseWriter

    /// A project or workspace record written (as it is now) or deleted, or a session deleted (its writes are pushed as
    /// `event.session` where its live state is known).
    public enum Change: Sendable {
        case repo(Repo), worktree(Worktree), repoRemoved(String), worktreeRemoved(String), sessionRemoved(String)
    }
    /// Told of every one, after its write: every write goes through here, so the daemon pushes them from one place.
    /// In a struct: a lock holding the function itself got it back wrapped once more on every read (the generic inout's
    /// conversion, in a debug build at least), so each change was told slower, and a few thousand overflowed the stack.
    public struct Listener: Sendable { public var tell: (@Sendable (Change) -> Void)? }
    public let changed = OSAllocatedUnfairLock(initialState: Listener())
    /// A write and its telling, one at a time: changes are told in the order they were committed. Told after a write
    /// that wasn't, two writers could pass each other in between, and the app keep the older record. Recursive: one
    /// told that writes again (none does now) goes on.
    private let ordered = NSRecursiveLock()
    private func report(_ record: Any, removed: Bool = false) {
        guard let tell = changed.withLock({ $0.tell }) else { return }
        if let repo = record as? Repo { tell(removed ? .repoRemoved(repo.id) : .repo(repo)) }
        if let worktree = record as? Worktree { tell(removed ? .worktreeRemoved(worktree.id) : .worktree(worktree)) }
        if let session = record as? Session, removed { tell(.sessionRemoved(session.id)) }
    }

    public init(path: String? = nil) throws {
        // WAL: every status, summary and UI-state change is a write, and the rollback journal fsynced each one twice.
        var config = Configuration()
        config.journalMode = .wal
        if let path { db = try DatabasePool(path: path, configuration: config) } else { db = try DatabaseQueue() }
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "repo") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("path", .text).notNull().unique()
                table.column("baseBranch", .text).notNull()
                table.column("copyFiles", .jsonText).notNull()
            }
            try db.create(table: "worktree") { table in
                table.primaryKey("id", .text)
                table.column("repoId", .text).notNull().references("repo", onDelete: .cascade)
                table.column("branch", .text).notNull()
                table.column("path", .text).notNull()
                table.column("note", .text).notNull()
                table.column("archived", .boolean).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "session") { table in
                table.primaryKey("id", .text)
                table.column("worktreeId", .text)
                table.column("cwd", .text).notNull()
                table.column("command", .text).notNull()
                table.column("agent", .text)
                table.column("status", .text).notNull()
                table.column("unread", .boolean).notNull()
                table.column("pid", .integer).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "diffComment") { table in
                table.primaryKey("id", .text)
                table.column("worktreeId", .text).notNull()
                table.column("file", .text).notNull()
                table.column("startLine", .integer).notNull()
                table.column("endLine", .integer).notNull()
                table.column("quote", .text).notNull()
                table.column("text", .text).notNull()
                table.column("state", .text).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "session") { table in
                table.add(column: "title", .text).notNull().defaults(to: "")
                table.add(column: "titleManual", .boolean).notNull().defaults(to: false)
                table.add(column: "summary", .text).notNull().defaults(to: "")
                table.add(column: "argv", .jsonText).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "worktree") { table in
                table.add(column: "issue", .text).notNull().defaults(to: "")
                table.add(column: "issueURL", .text).notNull().defaults(to: "")
                table.add(column: "linearIssueId", .text).notNull().defaults(to: "")
                table.add(column: "prNumber", .integer)
                table.add(column: "prURL", .text).notNull().defaults(to: "")
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "worktree") { t in t.add(column: "base", .text).notNull().defaults(to: "") }
        }
        migrator.registerMigration("v5") { db in
            try db.alter(table: "session") { t in t.add(column: "statusAt", .datetime) }
        }
        migrator.registerMigration("v6") { db in
            try db.create(table: "uiState") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
            // A workspace's layout goes with it, however it's removed (its project's removal cascades here too).
            try db.execute(
                sql:
                    "CREATE TRIGGER uiStateLayout AFTER DELETE ON worktree BEGIN DELETE FROM uiState WHERE key = 'layout/' || OLD.id; END"
            )
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "session") { t in t.add(column: "workDir", .text) }
        }
        migrator.registerMigration("v8") { db in
            try db.alter(table: "session") { t in t.add(column: "progress", .integer) }
        }
        migrator.registerMigration("v9") { db in
            try db.alter(table: "session") { t in t.add(column: "exitCode", .integer) }
        }
        migrator.registerMigration("v10") { db in
            try db.alter(table: "session") { t in t.add(column: "profile", .text) }
        }
        migrator.registerMigration("v11") { db in   // a workspace's review comments go with it (its project's removal included)
            try db.execute(sql: "DELETE FROM diffComment WHERE worktreeId NOT IN (SELECT id FROM worktree)")
            try db.execute(
                sql: """
                    CREATE TRIGGER worktreeComments AFTER DELETE ON worktree
                    BEGIN DELETE FROM diffComment WHERE worktreeId = OLD.id; END
                    """)
        }
        migrator.registerMigration("v12") { db in
            try db.alter(table: "session") { t in t.add(column: "tmux", .text) }
        }
        migrator.registerMigration("v13") { db in
            for table in ["repo", "worktree", "session"] {
                try db.alter(table: table) { t in t.add(column: "revision", .integer) }
            }
        }
        migrator.registerMigration("v14") { db in
            try db.alter(table: "session") { table in
                table.add(column: "goal", .text)
                table.add(column: "background", .text)
            }
        }
        migrator.registerMigration("v15") { db in
            try db.alter(table: "session") { t in t.add(column: "running", .text) }
        }
        migrator.registerMigration("v16") { db in
            try db.alter(table: "session") { t in t.add(column: "awaiting", .text) }
        }
        migrator.registerMigration("v17") { db in   // routines go with their project, runs with their routine
            try db.create(table: "routine") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("repoId", .text).notNull().references("repo", onDelete: .cascade)
                table.column("agent", .text).notNull()
                table.column("model", .text)
                table.column("prompt", .text).notNull()
                table.column("every", .text).notNull()
                table.column("time", .integer).notNull()
                table.column("weekday", .integer).notNull()
                table.column("enabled", .boolean).notNull()
                table.column("onWake", .boolean).notNull()
                table.column("worktreeId", .text)
                table.column("checked", .datetime).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "routineRun") { table in
                table.primaryKey("id", .text)
                table.column("routineId", .text).notNull().indexed().references("routine", onDelete: .cascade)
                table.column("sessionId", .text)
                table.column("due", .datetime).notNull()
                table.column("started", .datetime).notNull()
                table.column("ended", .datetime)
                table.column("outcome", .text).notNull()
                table.column("summary", .text).notNull()
            }
        }
        migrator.registerMigration("v18") { db in
            try db.alter(table: "session") { table in
                table.add(column: "limitHit", .text)
                table.add(column: "continueAt", .datetime)
            }
        }
        migrator.registerMigration("v19") { db in try db.alter(table: "session") { t in t.add(column: "parent", .text) }
        }
        migrator.registerMigration("v20") { db in
            try db.alter(table: "session") { t in t.add(column: "subagents", .text) }
        }
        migrator.registerMigration("v21") { db in
            try db.alter(table: "session") { t in t.add(column: "subagentTasks", .text) }
        }
        migrator.registerMigration("v22") { db in
            try db.create(table: "owedInput") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("session", .text).notNull().indexed().references("session", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("draft", .boolean).notNull()
                table.column("paste", .boolean).notNull()
                table.column("report", .boolean).notNull()
            }
        }
        migrator.registerMigration("v23") { db in
            try db.alter(table: "session") { t in t.add(column: "subagentRuns", .text) }
        }
        migrator.registerMigration("session.startedBy") { db in
            try db.alter(table: "session") { t in t.add(column: "startedBy", .text) }
        }
        migrator.registerMigration("session.browser") { db in
            try db.alter(table: "session") { t in t.add(column: "browser", .text) }
        }
        migrator.registerMigration("session.quiet") { db in
            try db.alter(table: "session") { table in
                table.add(column: "quietSince", .datetime)
                table.add(column: "guessed", .boolean)
            }
        }
        migrator.registerMigration("uiState.viewed") { db in   // a workspace's read marks go with it, as its layout does
            try db.execute(
                sql:
                    "CREATE TRIGGER uiStateViewed AFTER DELETE ON worktree BEGIN DELETE FROM uiState WHERE key = 'viewed/' || OLD.id; END"
            )
        }
        migrator.registerMigration("diffComment.side") { db in
            try db.alter(table: "diffComment") { table in
                table.add(column: "side", .text)
                table.add(column: "commit", .text)
            }
        }
        // an agent's turns, kept for the diff of any of them; they go with their session
        migrator.registerMigration("turn") { db in
            try db.create(table: "turn") { table in
                table.primaryKey("id", .text)
                table.column("session", .text).notNull().indexed()
                table.column("tree", .text).notNull()
                table.column("head", .text)
                table.column("folder", .text).notNull()
                table.column("prompt", .text).notNull()
                table.column("at", .datetime).notNull()
            }
            try db.execute(
                sql:
                    "CREATE TRIGGER sessionTurns AFTER DELETE ON session BEGIN DELETE FROM turn WHERE session = OLD.id; END"
            )
        }
        migrator.registerMigration("diffComment.author") { db in
            try db.alter(table: "diffComment") { t in t.add(column: "author", .text) }
        }
        migrator.registerMigration("diffComment.onCommit") { db in
            try db.alter(table: "diffComment") { t in t.add(column: "onCommit", .text) }
        }
        migrator.registerMigration("session.origin") { db in
            try db.alter(table: "session") { t in t.add(column: "origin", .text) }
        }
        migrator.registerMigration("worktree.madeBy") { db in
            try db.alter(table: "worktree") { t in t.add(column: "madeBy", .text) }
        }
        // a project's databases: added by hand, or what was changed of a found one
        migrator.registerMigration("database") { db in
            try db.create(table: "database") { t in
                t.primaryKey("id", .text)   // repoId/name
                t.column("repoId", .text).notNull().indexed().references("repo", onDelete: .cascade)
                t.column("byHand", .boolean).notNull()
                t.column("json", .text).notNull()   // the Database, as sent
            }
        }
        return migrator
    }

    public func repos() throws -> [Repo] { try db.read { try Repo.order(Column("name")).fetchAll($0) } }
    public func repo(_ id: String) throws -> Repo? { try db.read { try Repo.fetchOne($0, key: id) } }
    public func worktrees(repo: String? = nil) throws -> [Worktree] {
        try db.read { database in
            var query = Worktree.order(Column("createdAt"))
            if let repo { query = query.filter(Column("repoId") == repo) }
            return try query.fetchAll(database)
        }
    }
    public func worktree(_ id: String) throws -> Worktree? { try db.read { try Worktree.fetchOne($0, key: id) } }
    public func sessions() throws -> [Session] { try db.read { try Session.order(Column("createdAt")).fetchAll($0) } }
    public func session(_ id: String) throws -> Session? { try db.read { try Session.fetchOne($0, key: id) } }
    func owe(_ all: [OwedInput]) throws { try db.write { d in for input in all { try input.insert(d) } } }
    /// What's owed to `session`, in the order it came, and it's no longer kept here.
    func takeOwed(_ session: String) throws -> [OwedInput] {
        try db.write { database in
            let all = OwedInput.filter(Column("session") == session).order(Column("id"))
            let owed = try all.fetchAll(database)
            try all.deleteAll(database)
            return owed
        }
    }
    @discardableResult
    public func save<R: PersistableRecord>(_ record: R) throws -> R {
        try ordered.withLock {
            let saved = try db.write { database in try Self.revised(record, database).saved(database) }
            report(saved)
            return saved
        }
    }
    /// Changes a record (a workspace, a session) in one write: read, change, save with nothing in between. Saving a copy
    /// read earlier would put back fields someone else changed meanwhile (a rename, a PR, archiving). Nil when it's gone.
    @discardableResult
    public func update<R: FetchableRecord & PersistableRecord>(
        _: R.Type, _ id: String, _ change: (inout R) throws -> Void
    ) throws -> R? {
        try ordered.withLock {
            let updated: R? = try db.write { database in
                guard var record = try R.fetchOne(database, key: id) else { return nil }
                try change(&record)
                return try Self.revised(record, database).saved(database)
            }
            if let updated { report(updated) }
            return updated
        }
    }
    /// Only a row that's there: a session deleted meanwhile stays deleted (`save` would insert it again).
    @discardableResult
    public func update<R: PersistableRecord>(_ record: R) throws -> R {
        try ordered.withLock {
            let updated = try db.write { database in
                let revised = try Self.revised(record, database)
                try revised.update(database)
                return revised
            }
            report(updated)
            return updated
        }
    }

    /// The record with the next revision, read in the write that saves it: what a client gets later is newer.
    private static func revised<R: PersistableRecord>(_ record: R, _ database: Database) throws -> R {
        guard var revisable = record as? any Revised else { return record }
        let now =
            try Int.fetchOne(
                database, sql: "SELECT revision FROM \(R.databaseTableName) WHERE id = ?", arguments: [revisable.id])
            ?? 0
        revisable.revision = now + 1
        return revisable as? R ?? record
    }
    public func delete<R: PersistableRecord>(_ record: R) throws {
        try ordered.withLock {
            try db.write { _ = try record.delete($0) }
            report(record, removed: true)
        }
    }
    /// A session deleted, with the turns that go with it, read in the same write: none added meanwhile is missed.
    public func deleteSession(_ session: Session) throws -> [SessionTurns.Mark] {
        try ordered.withLock {
            let marks = try db.write { database in
                let marks = try SessionTurns.Mark.filter(Column("session") == session.id).order(Column("at").desc)
                    .fetchAll(database)
                _ = try session.delete(database)
                return marks
            }
            report(session, removed: true)
            return marks
        }
    }
    /// A turn that began; past `keep` of the session's, the oldest go, and are returned. nil, and nothing added, when its
    /// session is gone (deleted while the turn's snapshot was taken).
    @discardableResult
    public func addTurn(_ turn: SessionTurns.Mark, keep: Int = 20) throws -> [SessionTurns.Mark]? {
        try db.write { database in
            guard try Session.exists(database, key: turn.session) else { return nil }
            try turn.insert(database)
            let old = try SessionTurns.Mark.filter(Column("session") == turn.session).order(Column("at").desc).fetchAll(
                database
            )
            .dropFirst(keep)
            for mark in old { _ = try mark.delete(database) }
            return Array(old)
        }
    }
    /// The session's turns, the newest first.
    public func turns(session: String) throws -> [SessionTurns.Mark] {
        try db.read { try SessionTurns.Mark.filter(Column("session") == session).order(Column("at").desc).fetchAll($0) }
    }

    public func comments(worktree: String) throws -> [DiffComment] {
        try db.read { try DiffComment.filter(Column("worktreeId") == worktree).fetchAll($0) }
    }

    /// The app's UI state (`state.*`): JSON by key, e.g. `layout/<workspace>`, `sidebar.order`. Every key with this prefix.
    public func uiState(prefix: String) throws -> [String: JSONValue] {
        try db.read { database in
            try Row.fetchAll(
                database, sql: "SELECT key, value FROM uiState WHERE instr(key, ?) = 1", arguments: [prefix]
            )
            .reduce(into: [:]) { out, row in
                let text: String = row["value"]
                out[row["key"]] = Log.store.attempt("reading UI state \(row["key"] as String)") {
                    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                }
            }
        }
    }
    /// Whether a tab of `uri` (`session:<id>`) is in a workspace's saved layout: open, shown or not.
    public func inALayout(_ uri: String) throws -> Bool {
        try db.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS (SELECT 1 FROM uiState WHERE instr(key, 'layout/') = 1 AND instr(value, ?) > 0)",
                arguments: ["\"" + uri + "\""]) ?? false
        }
    }
    /// No value deletes the key.
    public func setUIState(_ key: String, _ value: JSONValue?) throws {
        let text = try value.flatMap { String(bytes: try JSONEncoder().encode($0), encoding: .utf8) }
        try db.write { database in
            if let text {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO uiState (key, value) VALUES (?, ?)", arguments: [key, text])
            } else {
                try database.execute(sql: "DELETE FROM uiState WHERE key = ?", arguments: [key])
            }
        }
    }
}

extension Store {
    /// The worktree a client named: one that isn't there is the client's error.
    func worktree(named id: String) throws -> Worktree {
        guard let found = try worktree(id) else { throw RPCError.invalidParams("no worktree \(id)") }
        return found
    }
}
