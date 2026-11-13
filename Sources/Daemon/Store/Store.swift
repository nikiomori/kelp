import Core
import Foundation
import GRDB
import os

/// SQLite persistence for repos, worktrees, sessions and diff comments.
final class Store: Sendable {
    /// A pool on disk: reads run beside a write (WAL) instead of queueing behind it, and many come from the cooperative
    /// pool and connection reader threads, where waiting on a status write's fsync would hold up keystrokes. A queue in
    /// memory (tests: a pool needs a file).
    /// Also the query surface of the records only one feature keeps (routines, comments, saved databases): they read and
    /// write their own tables through it. Those writes aren't told (`changed`): only projects, workspaces and sessions are.
    let db: any DatabaseWriter

    /// A project or workspace record written (as it is now) or deleted, or a session deleted (its writes are pushed as
    /// `event.session` where its live state is known).
    enum Change: Sendable {
        case repo(Repo), worktree(Worktree), repoRemoved(String), worktreeRemoved(String)
        case sessionRemoved(String, workspace: String?)
        /// Saved as ended (it stays a week, `keepEnded`): its workspace may have nobody left in it.
        case sessionEnded(workspace: String)
    }
    /// Told of every one, after its write: every write goes through here, so the daemon pushes them from one place.
    /// In a struct: a lock holding the function itself got it back wrapped once more on every read (the generic inout's
    /// conversion, in a debug build at least), so each change was told slower, and a few thousand overflowed the stack.
    struct Listener: Sendable { var tell: (@Sendable (Change) -> Void)? }
    let changed = OSAllocatedUnfairLock(initialState: Listener())
    /// A write and its telling, one at a time: changes are told in the order they were committed. Told after a write
    /// that wasn't, two writers could pass each other in between, and the app keep the older record. Recursive: one
    /// told that writes again (none does now) goes on.
    private let ordered = NSRecursiveLock()
    private func report(_ record: Any, removed: Bool = false) {
        guard let tell = changed.withLock({ $0.tell }) else { return }
        if let repo = record as? Repo { tell(removed ? .repoRemoved(repo.id) : .repo(repo)) }
        if let worktree = record as? Worktree { tell(removed ? .worktreeRemoved(worktree.id) : .worktree(worktree)) }
        if let session = record as? Session {
            if removed {
                tell(.sessionRemoved(session.id, workspace: session.worktreeId))
            } else if session.status == .exited, let workspace = session.worktreeId {
                tell(.sessionEnded(workspace: workspace))
            }
        }
    }

    init(path: String? = nil) throws {
        // WAL: every status, summary and UI-state change is a write, and the rollback journal fsynced each one twice.
        var config = Configuration()
        config.journalMode = .wal
        if let path { db = try DatabasePool(path: path, configuration: config) } else { db = try DatabaseQueue() }
        try Self.migrator.migrate(db)
    }

    func repos() throws -> [Repo] { try db.read { try Repo.order(Column("name")).fetchAll($0) } }
    func repo(_ id: String) throws -> Repo? { try db.read { try Repo.fetchOne($0, key: id) } }
    func worktrees(repo: String? = nil) throws -> [Worktree] {
        try db.read { database in
            var query = Worktree.order(Column("createdAt"))
            if let repo { query = query.filter(Column("repoId") == repo) }
            return try query.fetchAll(database)
        }
    }
    func worktree(_ id: String) throws -> Worktree? { try db.read { try Worktree.fetchOne($0, key: id) } }
    func sessions() throws -> [Session] { try db.read { try Session.order(Column("createdAt")).fetchAll($0) } }
    func session(_ id: String) throws -> Session? { try db.read { try Session.fetchOne($0, key: id) } }
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
    func save<R: PersistableRecord>(_ record: R) throws -> R {
        try ordered.withLock {
            let saved = try db.write { database in try Self.revised(record, database).saved(database) }
            report(saved)
            return saved
        }
    }
    /// Changes a record (a workspace, a session) in one write: read, change, save with nothing in between. Saving a copy
    /// read earlier would put back fields someone else changed meanwhile (a rename, a PR, archiving). Nil when it's gone.
    /// A change that leaves it as it was isn't one: no new revision, no write, nothing told.
    @discardableResult
    func update<R: FetchableRecord & PersistableRecord & Equatable>(
        _: R.Type, _ id: String, _ change: (inout R) throws -> Void
    ) throws -> R? {
        try ordered.withLock {
            let (record, changed): (R?, Bool) = try db.write { database in
                guard var record = try R.fetchOne(database, key: id) else { return (nil, false) }
                let before = record
                try change(&record)
                guard record != before else { return (record, false) }
                return (try Self.revised(record, database).saved(database), true)
            }
            if let record, changed { report(record) }
            return record
        }
    }
    /// Only a row that's there: a session deleted meanwhile stays deleted (`save` would insert it again).
    @discardableResult
    func update<R: PersistableRecord>(_ record: R) throws -> R {
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
    func delete<R: PersistableRecord>(_ record: R) throws {
        try ordered.withLock {
            try db.write { _ = try record.delete($0) }
            report(record, removed: true)
        }
    }
    /// A session deleted, with the turns that go with it, read in the same write: none added meanwhile is missed.
    func deleteSession(_ session: Session) throws -> [SessionTurns.Mark] {
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
    func addTurn(_ turn: SessionTurns.Mark, keep: Int = 20) throws -> [SessionTurns.Mark]? {
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
    /// The turns any agent began in `folder`, the oldest first: the last `limit`.
    func turns(folder: String, limit: Int = 100) throws -> [SessionTurns.Mark] {
        try db.read {
            try SessionTurns.Mark.filter(Column("folder") == folder).order(Column("at").desc).limit(limit).fetchAll($0)
        }
        .reversed()
    }
    /// The session's turns, the newest first.
    func turns(session: String) throws -> [SessionTurns.Mark] {
        try db.read { try SessionTurns.Mark.filter(Column("session") == session).order(Column("at").desc).fetchAll($0) }
    }

    func comments(worktree: String) throws -> [DiffComment] {
        try db.read { try DiffComment.filter(Column("worktreeId") == worktree).fetchAll($0) }
    }

    /// The app's UI state (`state.*`): JSON by key, e.g. `layout/<workspace>`, `sidebar.order`. Every key with this prefix.
    func uiState(prefix: String) throws -> [String: JSONValue] {
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
    func inALayout(_ uri: String) throws -> Bool {
        try db.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS (SELECT 1 FROM uiState WHERE instr(key, 'layout/') = 1 AND instr(value, ?) > 0)",
                arguments: ["\"" + uri + "\""]) ?? false
        }
    }
    /// The keys of the user's trust: Kelp's window writes them with `state.set` and reads them back with `state.get`, as
    /// the rest of its state, but they're kept in `daemonState`, where nothing else the window or a script saves goes.
    static let trustKeys: Set<String> = [LSPOpen.trustKey, ExtensionFiles.extensionTrustKey]

    /// What the daemon keeps apart from the app's own state, JSON by key: the user's trust (`trustKeys`), which it
    /// decides by, and what it keeps for itself (`Forwards`). Each is written by the one method that owns it.
    func daemonState<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM daemonState WHERE key = ?", arguments: [key]) }
            .map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
    /// No value deletes the key.
    func setDaemonState(_ key: String, _ value: (some Encodable)?) throws {
        let text = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.write { database in
            if let text {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO daemonState (key, value) VALUES (?, ?)", arguments: [key, text])
            } else {
                try database.execute(sql: "DELETE FROM daemonState WHERE key = ?", arguments: [key])
            }
        }
    }

    /// No value deletes the key.
    func setUIState(_ key: String, _ value: JSONValue?) throws {
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

extension Store {
    /// What `read` finds; nil when the store couldn't answer, which is logged: for a look its caller goes on without.
    func look<T>(_ what: @autoclosure () -> String, _ read: (Store) throws -> T?) -> T? {
        Log.store.attempt(what()) { try read(self) } ?? nil
    }
}
