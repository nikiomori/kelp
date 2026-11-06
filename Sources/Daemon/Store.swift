import Foundation
import os
import GRDB
import Core

/// SQLite persistence for repos, worktrees, sessions and diff comments.
public final class Store: Sendable {
    /// A pool on disk: reads run beside a write (WAL) instead of queueing behind it, and many come from the cooperative
    /// pool and connection reader threads, where waiting on a status write's fsync would hold up keystrokes. A queue in
    /// memory (tests: a pool needs a file).
    public let db: any DatabaseWriter

    /// A project or workspace record written (as it is now) or deleted, or a session deleted (its writes are pushed as
    /// `event.session` where its live state is known).
    public enum Change: Sendable { case repo(Repo), worktree(Worktree), repoRemoved(String), worktreeRemoved(String), sessionRemoved(String) }
    /// Told of every one, after its write: every write goes through here, so the daemon pushes them from one place.
    /// In a struct: a lock holding the function itself got it back wrapped once more on every read (the generic inout's
    /// conversion, in a debug build at least), so each change was told slower, and a few thousand overflowed the stack.
    public struct Listener: Sendable { public var tell: (@Sendable (Change) -> Void)? }
    public let changed = OSAllocatedUnfairLock(initialState: Listener())
    /// A write and its telling, one at a time: changes are told in the order they were committed. Told after a write
    /// that wasn't, two writers could pass each other in between, and the app keep the older record. Recursive: one
    /// told that writes again (none does now) goes on.
    private let ordered = NSRecursiveLock()
    private func report(_ r: Any, removed: Bool = false) {
        guard let tell = changed.withLock({ $0.tell }) else { return }
        if let x = r as? Repo { tell(removed ? .repoRemoved(x.id) : .repo(x)) }
        if let x = r as? Worktree { tell(removed ? .worktreeRemoved(x.id) : .worktree(x)) }
        if let x = r as? Session, removed { tell(.sessionRemoved(x.id)) }
    }

    public init(path: String? = nil) throws {
        // WAL: every status, summary and UI-state change is a write, and the rollback journal fsynced each one twice.
        var config = Configuration(); config.journalMode = .wal
        if let path { db = try DatabasePool(path: path, configuration: config) } else { db = try DatabaseQueue() }
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text); t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique(); t.column("baseBranch", .text).notNull()
                t.column("copyFiles", .jsonText).notNull()
            }
            try db.create(table: "worktree") { t in
                t.primaryKey("id", .text)
                t.column("repoId", .text).notNull().references("repo", onDelete: .cascade)
                t.column("branch", .text).notNull(); t.column("path", .text).notNull()
                t.column("note", .text).notNull(); t.column("archived", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "session") { t in
                t.primaryKey("id", .text); t.column("worktreeId", .text)
                t.column("cwd", .text).notNull(); t.column("command", .text).notNull()
                t.column("agent", .text); t.column("status", .text).notNull()
                t.column("unread", .boolean).notNull(); t.column("pid", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "diffComment") { t in
                t.primaryKey("id", .text); t.column("worktreeId", .text).notNull()
                t.column("file", .text).notNull(); t.column("startLine", .integer).notNull()
                t.column("endLine", .integer).notNull(); t.column("quote", .text).notNull()
                t.column("text", .text).notNull(); t.column("state", .text).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "session") { t in
                t.add(column: "title", .text).notNull().defaults(to: "")
                t.add(column: "titleManual", .boolean).notNull().defaults(to: false)
                t.add(column: "summary", .text).notNull().defaults(to: "")
                t.add(column: "argv", .jsonText).notNull().defaults(to: "[]")
            }
        }
        m.registerMigration("v3") { db in
            try db.alter(table: "worktree") { t in
                t.add(column: "issue", .text).notNull().defaults(to: "")
                t.add(column: "issueURL", .text).notNull().defaults(to: "")
                t.add(column: "linearIssueId", .text).notNull().defaults(to: "")
                t.add(column: "prNumber", .integer)
                t.add(column: "prURL", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v4") { db in
            try db.alter(table: "worktree") { t in t.add(column: "base", .text).notNull().defaults(to: "") }
        }
        m.registerMigration("v5") { db in
            try db.alter(table: "session") { t in t.add(column: "statusAt", .datetime) }
        }
        m.registerMigration("v6") { db in
            try db.create(table: "uiState") { t in t.primaryKey("key", .text); t.column("value", .text).notNull() }
            // A workspace's layout goes with it, however it's removed (its project's removal cascades here too).
            try db.execute(sql: "CREATE TRIGGER uiStateLayout AFTER DELETE ON worktree BEGIN DELETE FROM uiState WHERE key = 'layout/' || OLD.id; END")
        }
        m.registerMigration("v7") { db in
            try db.alter(table: "session") { t in t.add(column: "workDir", .text) }
        }
        m.registerMigration("v8") { db in
            try db.alter(table: "session") { t in t.add(column: "progress", .integer) }
        }
        m.registerMigration("v9") { db in
            try db.alter(table: "session") { t in t.add(column: "exitCode", .integer) }
        }
        m.registerMigration("v10") { db in
            try db.alter(table: "session") { t in t.add(column: "profile", .text) }
        }
        m.registerMigration("v11") { db in   // a workspace's review comments go with it (its project's removal included)
            try db.execute(sql: "DELETE FROM diffComment WHERE worktreeId NOT IN (SELECT id FROM worktree)")
            try db.execute(sql: """
                CREATE TRIGGER worktreeComments AFTER DELETE ON worktree
                BEGIN DELETE FROM diffComment WHERE worktreeId = OLD.id; END
                """)
        }
        m.registerMigration("v12") { db in
            try db.alter(table: "session") { t in t.add(column: "tmux", .text) }
        }
        m.registerMigration("v13") { db in
            for table in ["repo", "worktree", "session"] { try db.alter(table: table) { t in t.add(column: "revision", .integer) } }
        }
        m.registerMigration("v14") { db in
            try db.alter(table: "session") { t in t.add(column: "goal", .text); t.add(column: "background", .text) }
        }
        m.registerMigration("v15") { db in
            try db.alter(table: "session") { t in t.add(column: "running", .text) }
        }
        m.registerMigration("v16") { db in
            try db.alter(table: "session") { t in t.add(column: "awaiting", .text) }
        }
        m.registerMigration("v17") { db in   // routines go with their project, runs with their routine
            try db.create(table: "routine") { t in
                t.primaryKey("id", .text); t.column("name", .text).notNull()
                t.column("repoId", .text).notNull().references("repo", onDelete: .cascade)
                t.column("agent", .text).notNull(); t.column("model", .text)
                t.column("prompt", .text).notNull(); t.column("every", .text).notNull()
                t.column("time", .integer).notNull(); t.column("weekday", .integer).notNull()
                t.column("enabled", .boolean).notNull(); t.column("onWake", .boolean).notNull()
                t.column("worktreeId", .text); t.column("checked", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "routineRun") { t in
                t.primaryKey("id", .text)
                t.column("routineId", .text).notNull().indexed().references("routine", onDelete: .cascade)
                t.column("sessionId", .text); t.column("due", .datetime).notNull()
                t.column("started", .datetime).notNull(); t.column("ended", .datetime)
                t.column("outcome", .text).notNull(); t.column("summary", .text).notNull()
            }
        }
        m.registerMigration("v18") { db in
            try db.alter(table: "session") { t in t.add(column: "limitHit", .text); t.add(column: "continueAt", .datetime) }
        }
        m.registerMigration("v19") { db in try db.alter(table: "session") { t in t.add(column: "parent", .text) } }
        m.registerMigration("v20") { db in try db.alter(table: "session") { t in t.add(column: "subagents", .text) } }
        m.registerMigration("v21") { db in try db.alter(table: "session") { t in t.add(column: "subagentTasks", .text) } }
        m.registerMigration("v22") { db in
            try db.create(table: "owedInput") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session", .text).notNull().indexed().references("session", onDelete: .cascade)
                t.column("text", .text).notNull(); t.column("draft", .boolean).notNull()
                t.column("paste", .boolean).notNull(); t.column("report", .boolean).notNull()
            }
        }
        m.registerMigration("v23") { db in try db.alter(table: "session") { t in t.add(column: "subagentRuns", .text) } }
        m.registerMigration("session.startedBy") { db in try db.alter(table: "session") { t in t.add(column: "startedBy", .text) } }
        m.registerMigration("session.browser") { db in try db.alter(table: "session") { t in t.add(column: "browser", .text) } }
        m.registerMigration("session.quiet") { db in
            try db.alter(table: "session") { t in t.add(column: "quietSince", .datetime); t.add(column: "guessed", .boolean) }
        }
        m.registerMigration("uiState.viewed") { db in   // a workspace's read marks go with it, as its layout does
            try db.execute(sql: "CREATE TRIGGER uiStateViewed AFTER DELETE ON worktree BEGIN DELETE FROM uiState WHERE key = 'viewed/' || OLD.id; END")
        }
        m.registerMigration("diffComment.side") { db in
            try db.alter(table: "diffComment") { t in t.add(column: "side", .text); t.add(column: "commit", .text) }
        }
        m.registerMigration("turn") { db in   // an agent's turns, kept for the diff of any of them; they go with their session
            try db.create(table: "turn") { t in
                t.primaryKey("id", .text)
                t.column("session", .text).notNull().indexed()
                t.column("tree", .text).notNull()
                t.column("head", .text)
                t.column("folder", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("at", .datetime).notNull()
            }
            try db.execute(sql: "CREATE TRIGGER sessionTurns AFTER DELETE ON session BEGIN DELETE FROM turn WHERE session = OLD.id; END")
        }
        m.registerMigration("diffComment.author") { db in try db.alter(table: "diffComment") { t in t.add(column: "author", .text) } }
        m.registerMigration("diffComment.onCommit") { db in try db.alter(table: "diffComment") { t in t.add(column: "onCommit", .text) } }
        m.registerMigration("session.origin") { db in try db.alter(table: "session") { t in t.add(column: "origin", .text) } }
        m.registerMigration("worktree.madeBy") { db in try db.alter(table: "worktree") { t in t.add(column: "madeBy", .text) } }
        return m
    }

    public func repos() throws -> [Repo] { try db.read { try Repo.order(Column("name")).fetchAll($0) } }
    public func repo(_ id: String) throws -> Repo? { try db.read { try Repo.fetchOne($0, key: id) } }
    public func worktrees(repo: String? = nil) throws -> [Worktree] {
        try db.read { d in
            var q = Worktree.order(Column("createdAt"))
            if let repo { q = q.filter(Column("repoId") == repo) }
            return try q.fetchAll(d)
        }
    }
    public func worktree(_ id: String) throws -> Worktree? { try db.read { try Worktree.fetchOne($0, key: id) } }
    public func sessions() throws -> [Session] { try db.read { try Session.order(Column("createdAt")).fetchAll($0) } }
    public func session(_ id: String) throws -> Session? { try db.read { try Session.fetchOne($0, key: id) } }
    func owe(_ all: [OwedInput]) throws { try db.write { d in for o in all { try o.insert(d) } } }
    /// What's owed to `session`, in the order it came, and it's no longer kept here.
    func takeOwed(_ session: String) throws -> [OwedInput] {
        try db.write { d in
            let all = OwedInput.filter(Column("session") == session).order(Column("id"))
            let owed = try all.fetchAll(d)
            try all.deleteAll(d)
            return owed
        }
    }
    @discardableResult
    public func save<R: PersistableRecord>(_ r: R) throws -> R {
        try ordered.withLock {
            let r = try db.write { d in try Self.revised(r, d).saved(d) }
            report(r)
            return r
        }
    }
    /// Changes a record (a workspace, a session) in one write: read, change, save with nothing in between. Saving a copy
    /// read earlier would put back fields someone else changed meanwhile (a rename, a PR, archiving). Nil when it's gone.
    @discardableResult
    public func update<R: FetchableRecord & PersistableRecord>(_: R.Type, _ id: String, _ change: (inout R) throws -> Void) throws -> R? {
        try ordered.withLock {
            let r: R? = try db.write { d in
                guard var r = try R.fetchOne(d, key: id) else { return nil }
                try change(&r); return try Self.revised(r, d).saved(d)
            }
            if let r { report(r) }
            return r
        }
    }
    /// Only a row that's there: a session deleted meanwhile stays deleted (`save` would insert it again).
    @discardableResult
    public func update<R: PersistableRecord>(_ r: R) throws -> R {
        try ordered.withLock {
            let r = try db.write { d in
                let x = try Self.revised(r, d)
                try x.update(d)
                return x
            }
            report(r)
            return r
        }
    }

    /// The record with the next revision, read in the write that saves it: what a client gets later is newer.
    private static func revised<R: PersistableRecord>(_ r: R, _ d: Database) throws -> R {
        guard var x = r as? any Revised else { return r }
        let now = try Int.fetchOne(d, sql: "SELECT revision FROM \(R.databaseTableName) WHERE id = ?", arguments: [x.id]) ?? 0
        x.revision = now + 1
        return x as? R ?? r
    }
    public func delete<R: PersistableRecord>(_ r: R) throws { try ordered.withLock { try db.write { _ = try r.delete($0) }; report(r, removed: true) } }
    /// A session deleted, with the turns that go with it, read in the same write: none added meanwhile is missed.
    public func deleteSession(_ s: Session) throws -> [SessionTurns.Mark] {
        try ordered.withLock {
            let marks = try db.write { d in
                let marks = try SessionTurns.Mark.filter(Column("session") == s.id).order(Column("at").desc).fetchAll(d)
                _ = try s.delete(d)
                return marks
            }
            report(s, removed: true)
            return marks
        }
    }
    /// A turn that began; past `keep` of the session's, the oldest go, and are returned. nil, and nothing added, when its
    /// session is gone (deleted while the turn's snapshot was taken).
    @discardableResult
    public func addTurn(_ t: SessionTurns.Mark, keep: Int = 20) throws -> [SessionTurns.Mark]? {
        try db.write { d in
            guard try Session.exists(d, key: t.session) else { return nil }
            try t.insert(d)
            let old = try SessionTurns.Mark.filter(Column("session") == t.session).order(Column("at").desc).fetchAll(d).dropFirst(keep)
            for m in old { _ = try m.delete(d) }
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
        try db.read { d in
            try Row.fetchAll(d, sql: "SELECT key, value FROM uiState WHERE instr(key, ?) = 1", arguments: [prefix]).reduce(into: [:]) { out, r in
                let text: String = r["value"]
                out[r["key"]] = Log.store.attempt("reading UI state \(r["key"] as String)") { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
            }
        }
    }
    /// Whether a tab of `uri` (`session:<id>`) is in a workspace's saved layout: open, shown or not.
    public func inALayout(_ uri: String) throws -> Bool {
        try db.read { d in
            try Bool.fetchOne(d, sql: "SELECT EXISTS (SELECT 1 FROM uiState WHERE instr(key, 'layout/') = 1 AND instr(value, ?) > 0)",
                              arguments: ["\"" + uri + "\""]) ?? false
        }
    }
    /// No value deletes the key.
    public func setUIState(_ key: String, _ value: JSONValue?) throws {
        let text = try value.flatMap { String(bytes: try JSONEncoder().encode($0), encoding: .utf8) }
        try db.write { d in
            if let text { try d.execute(sql: "INSERT OR REPLACE INTO uiState (key, value) VALUES (?, ?)", arguments: [key, text]) }
            else { try d.execute(sql: "DELETE FROM uiState WHERE key = ?", arguments: [key]) }
        }
    }
}

extension Store {
    /// The worktree a client named: one that isn't there is the client's error.
    func worktree(named id: String) throws -> Worktree {
        guard let w = try worktree(id) else { throw RPCError.invalidParams("no worktree \(id)") }
        return w
    }
}
