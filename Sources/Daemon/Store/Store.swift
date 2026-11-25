import Core
import Foundation
import GRDB
import GitKit
import os

/// SQLite persistence for repos, worktrees, sessions and diff comments.
final class Store: Sendable {
    /// The database. On disk it is a pool, so reads run beside a write (WAL) instead of queueing behind it. Many reads
    /// come from the cooperative pool and the connections' reader threads, where waiting on a status write's fsync
    /// would hold up keystrokes. In memory (tests) it is a queue, because a pool needs a file.
    /// The features that keep records of their own (routines, comments, saved databases) also read and write their
    /// tables through it. Those writes aren't reported (`changed`); only projects, workspaces and sessions are.
    let db: any DatabaseWriter

    /// A project or workspace record written (as it is now) or deleted, or a session deleted (its writes are pushed as
    /// `event.session` where its live state is known).
    enum Change: Sendable {
        case repo(Repo), worktree(Worktree), repoRemoved(String), worktreeRemoved(String)
        case sessionRemoved(String, workspace: String?)
        /// A session saved as ended (it stays a week, `keepEnded`), so its workspace may have nobody left in it.
        case sessionEnded(workspace: String)
    }
    /// Hears of every change, after its write. Every write goes through here, so the daemon pushes changes from one
    /// place.
    /// The function sits in a struct because a lock holding the bare function handed it back wrapped once more on every
    /// read (the generic inout's conversion, in a debug build at least). Each change was then told more slowly, and a
    /// few thousand overflowed the stack.
    struct Listener: Sendable { var tell: (@Sendable (Change) -> Void)? }
    let changed = OSAllocatedUnfairLock(initialState: Listener())
    /// Takes a write and its report one at a time, so changes are reported in the order they were committed. Without
    /// this lock, two writers could pass each other between a write and its report, and the app would keep the older
    /// record. The lock is recursive, so a listener that writes again (none does now) goes on.
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

    /// Makes a consistent copy at `path` while this store goes on writing (an update's adopt check opens it).
    func copy(to path: URL) throws { try db.backup(to: try DatabaseQueue(path: path.path)) }

    func repos() throws -> [Repo] { try db.read { try Repo.order(Column("name")).fetchAll($0) } }
    func repo(_ id: String) throws -> Repo? {
        if let nested = RepoKey.parts(id) {
            // A repository inside a project made of several (`RepoKey`): its main checkout, with its own base branch.
            guard let project = try repo(nested.id), Git.nestedRepos(project.path).contains(nested.name) else {
                return nil
            }
            let path = project.path + "/" + nested.name
            return Repo(
                id: id, name: nested.name, path: path, baseBranch: Git.defaultBranchFromFiles(path),
                copyFiles: project.copyFiles)
        }
        return try db.read { try Repo.fetchOne($0, key: id) }
    }
    func worktrees(repo: String? = nil) throws -> [Worktree] {
        try db.read { database in
            var query = Worktree.order(Column("createdAt"))
            if let repo { query = query.filter(Column("repoId") == repo) }
            return try query.fetchAll(database)
        }
    }
    func worktree(_ id: String) throws -> Worktree? { try db.read { try Worktree.fetchOne($0, key: id) } }
    /// The folder the git, PR and CI reads take by id: a workspace, or a chat's own branch folder
    /// (`Session.branchKey`). That one is no workspace and is made up here, for these reads alone, so nothing Kelp does
    /// to a workspace (close, remove, tidy a merged branch) can reach the agent's folder.
    /// A repository inside a folder that holds several is named by a `RepoKey` and made up here too: it belongs to the
    /// made-up project of the same name (`repo`), so its base branch and main checkout are its own.
    func gitPlace(_ id: String) throws -> Worktree? {
        if let nested = RepoKey.parts(id) {
            guard let home = try gitPlace(nested.id), Git.nestedRepos(home.path).contains(nested.name) else {
                return nil
            }
            let folder = home.path + "/" + nested.name
            return Worktree(
                id: id, repoId: RepoKey.of(home.repoId, nested.name), branch: Git.headBranch(folder) ?? "",
                path: folder)
        }
        guard id.hasPrefix(Session.branchKeyPrefix) else { return try worktree(id) }
        guard let chat = try session(String(id.dropFirst(Session.branchKeyPrefix.count))),
            let folder = chat.branchFolder, let home = try chat.worktreeId.flatMap(worktree)
        else { return nil }
        return Worktree(id: id, repoId: home.repoId, branch: Git.headBranch(folder) ?? "", path: folder)
    }
    func gitPlace(named id: String) throws -> Worktree {
        guard let found = try gitPlace(id) else { throw RPCError.noWorkspace(id) }
        return found
    }
    func sessions() throws -> [Session] { try db.read { try Session.order(Column("createdAt")).fetchAll($0) } }
    func session(_ id: String) throws -> Session? { try db.read { try Session.fetchOne($0, key: id) } }
    /// The sessions these parents started (`parent`), read through that column's index.
    func children(of parents: Set<String>) throws -> [Session] {
        try db.read { try Session.filter(parents.contains(Column("parent"))).fetchAll($0) }
    }
    func owe(_ all: [OwedInput]) throws { try db.write { d in for input in all { try input.insert(d) } } }
    /// Returns the input owed to `session`, in the order it came, and removes it from the store.
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
    /// Changes a record (a workspace, a session) in one write: read, change, save with nothing in between. Saving a
    /// copy read earlier would put back fields someone else changed meanwhile (a rename, a PR, archiving). Returns nil
    /// when the record is gone. A change that leaves the record as it was doesn't count, so there is no new revision,
    /// no write and no report.
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
    /// Updates only a row that's there, so a session deleted meanwhile stays deleted (`save` would insert it again).
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

    /// Returns the record with the next revision, read in the write that saves it, so what a client gets later is
    /// newer.
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
    /// Deletes a session and returns its turns, read in the same write so no turn added meanwhile is missed.
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
    /// Adds a turn that began. When the session has more than `keep` turns, the oldest are deleted and returned.
    /// Returns nil, adding nothing, when the session is gone (deleted while the turn's snapshot was taken).
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
    /// The last `limit` turns any agent began in `folder`, the oldest first.
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

    /// The app's UI state (`state.*`): JSON stored by key, e.g. `layout/<workspace>` or `sidebar.order`. This returns
    /// every key with the given prefix.
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
    static let trustKeys: Set<String> = [
        LSPOpen.trustKey, ExtensionFiles.extensionTrustKey, Repo.devContainerKey, Repo.machineKey
    ]

    /// Reads what the daemon keeps apart from the app's own state, as JSON by key: the user's trust (`trustKeys`),
    /// which the daemon decides by, and what it keeps for itself (`Forwards`). Each key is written by the one method
    /// that owns it.
    func daemonState<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM daemonState WHERE key = ?", arguments: [key]) }
            .map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
    /// A nil value deletes the key.
    func setDaemonState(_ key: String, _ value: (some Encodable)?) throws { try set("daemonState", key, value) }
    func setUIState(_ key: String, _ value: JSONValue?) throws { try set("uiState", key, value) }

    private func set(_ table: String, _ key: String, _ value: (some Encodable)?) throws {
        let text = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.write { database in
            if let text {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO \(table) (key, value) VALUES (?, ?)", arguments: [key, text])
            } else {
                try database.execute(sql: "DELETE FROM \(table) WHERE key = ?", arguments: [key])
            }
        }
    }
}

extension Store {
    /// The worktree a client named: one that isn't there is the client's error.
    func worktree(named id: String) throws -> Worktree {
        guard let found = try worktree(id) else { throw RPCError.noWorkspace(id) }
        return found
    }
}

extension Store {
    /// Returns what `read` finds, or nil when the store couldn't answer, which is logged. It is for a look its caller
    /// can go on without.
    func look<T>(_ what: @autoclosure () -> String, _ read: (Store) throws -> T?) -> T? {
        Log.store.attempt(what()) { try read(self) } ?? nil
    }
}
