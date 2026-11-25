import Core
import Foundation
import GRDB
import os

// The databases as an agent's turn found them, kept beside the turn's snapshot of the files, so that Undo Turn puts
// them back too. Only what Kelp can make again is kept: a SQLite or DuckDB file on this Mac, cloned when the turn
// begins (an APFS clone takes no room until the file changes), and a branch's own Postgres copy on this Mac, made into
// a database of its own (TEMPLATE) before the turn's first `kelp db` change. A team's server is never touched.

/// What Kelp keeps of one database for a turn, or of the state an undo left (for Redo). It is listed in `kept.json`,
/// in the turn's folder under turn-databases/.
struct KeptDatabase: Codable, Sendable, Equatable {
    var worktreeId: String, name: String, engine: DatabaseInfo.Engine
    /// The database's file, and the size and last write of it and of its log when it was kept: they differ once the
    /// project's code (a migration, a test) changed it.
    var path: String?, stamp: [Double]?
    /// The Postgres database that holds the copy as it was.
    var template: String?
    /// Why it couldn't be kept, such as a dev server connected to the Postgres copy.
    var cannot: String?
    /// What the agent changed in it with `kelp db` during the turn.
    var runs: [DatabaseRun] = []
}

/// Where the turns' databases are kept, and what keeps and puts back a file.
final class TurnDatabases: Sendable {
    let dir: URL
    private struct Owner: Sendable { weak var databases: Databases? }
    private let owner = OSAllocatedUnfairLock(initialState: Owner())
    private let lock = NSLock()   // one change to a kept.json at a time

    init(root: URL) { dir = root.appendingPathComponent("turn-databases") }

    /// The projects' databases, which set themselves here as they start (they need the sessions, which need this).
    var databases: Databases? {
        get { owner.withLock { $0.databases } }
        set { owner.withLock { $0.databases = newValue } }
    }

    /// The folder of a turn (its id) or of a session's undone state ("undone-<session>").
    func folder(_ key: String) -> URL { dir.appendingPathComponent(key, isDirectory: true) }

    func kept(_ key: String) -> [KeptDatabase] {
        guard let data = FileManager.default.contents(atPath: folder(key).appendingPathComponent("kept.json").path)
        else { return [] }
        return Log.store.attempt("reading \(key)'s kept databases") {
            try JSONDecoder().decode([KeptDatabase].self, from: data)
        } ?? []
    }

    /// Changes what is kept for `key` in one step, so two calls of the turn don't drop each other's runs.
    func change(_ key: String, _ body: (inout [KeptDatabase]) throws -> Void) throws {
        try lock.withLock {
            var all = kept(key)
            try body(&all)
            let file = folder(key).appendingPathComponent("kept.json")
            try FileManager.default.createDirectory(at: folder(key), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
        }
    }

    /// Forgets what was kept for `keys`: the files go, and a Postgres copy kept as a database is dropped.
    func drop(_ keys: [String]) {
        for key in keys {
            let templates = kept(key).filter { $0.template != nil }
            FileManager.default.removeIfAny(folder(key))
            guard let databases, !templates.isEmpty else { continue }
            Task { await databases.dropTemplates(templates) }
        }
    }

    /// Takes the Postgres copies kept of the database `name` in `worktreeId` out of every turn's list, for them to be
    /// dropped as the branch's copy goes: once it is gone, nothing says which server they are on. Undoing such a turn
    /// says why it can't put that database back.
    func takeTemplates(of name: String, in worktreeId: String) -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let keys =
            Log.store.attempt("listing the turns' databases") {
                try FileManager.default.contentsOfDirectory(atPath: dir.path)
            } ?? []
        var taken: [String] = []
        for key in keys where kept(key).contains(where: { $0.name == name && $0.worktreeId == worktreeId }) {
            Log.store.attempt("forgetting \(name)'s copies kept for \(key)") {
                try change(key) { all in
                    for i in all.indices where all[i].name == name && all[i].worktreeId == worktreeId {
                        guard let template = all[i].template else { continue }
                        taken.append(template)
                        all[i].template = nil
                        all[i].cannot = "Its branch's copy was removed."
                    }
                }
            }
        }
        return taken
    }

    /// The file a database is kept in, numbered in its turn's folder.
    func file(_ key: String, _ index: Int) -> String { folder(key).appendingPathComponent("\(index).db").path }

    // MARK: Files

    /// The log beside a database's file, which holds changes not yet written into it.
    static func log(_ path: String, _ engine: DatabaseInfo.Engine) -> String {
        engine == .duckdb ? path + ".wal" : path + "-wal"
    }

    /// The file's size and last write, and its log's (an empty log counts as none): what tells a file changed.
    static func stamp(_ path: String, _ engine: DatabaseInfo.Engine) -> [Double] {
        [path, log(path, engine)].flatMap { file -> [Double] in
            var info = stat()
            guard stat(file, &info) == 0, info.st_size > 0 else { return [0, 0] }
            return [Double(info.st_size), FileManager.default.modified(file)?.timeIntervalSince1970 ?? 0]
        }
    }

    /// Clones a database's file and its log into `target`, as one: SQLite's are cloned inside a read, so no checkpoint
    /// writes the log into the file, nor does the log start over, in between. The clone is then made one file without
    /// a log, so SQLite's backup can put it back.
    static func clone(_ path: String, _ engine: DatabaseInfo.Engine, to target: String) throws {
        let both = {
            try cloneFile(path, to: target)
            if FileManager.default.fileExists(atPath: log(path, engine)) {
                try cloneFile(log(path, engine), to: log(target, engine))
            }
        }
        guard engine == .sqlite else { return try both() }
        try SQLiteRun.open(path, readOnly: true).read { db in
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            try both()
        }
        let copy = try DatabaseQueue(path: target)
        try copy.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try copy.close()
    }

    /// An APFS clone, which takes no room until one of the two changes. A volume that can't clone (not APFS) keeps
    /// nothing, rather than copying a database whole at every turn.
    private static func cloneFile(_ path: String, to target: String) throws {
        FileManager.default.removeIfAny(URL(fileURLWithPath: target))
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard clonefile(path, target, 0) == 0 else {
            throw DatabaseFailure.failed("\(path) couldn't be cloned (\(String(cString: strerror(errno)))).")
        }
    }

    /// Puts a database's file back from a clone (`clone`). SQLite's goes back through SQLite's backup, which takes the
    /// file's locks and its log as any writer does, in one transaction. DuckDB's file and log are cloned beside them,
    /// then moved over them, so a clone that fails leaves them as they were.
    static func putBack(_ path: String, _ engine: DatabaseInfo.Engine, from clone: String) throws {
        guard engine == .duckdb else { return try SQLiteRun.copy(clone, to: path) }
        let log = Self.log(path, engine), cloneLog = Self.log(clone, engine), aside = ".kelp-back"
        let logs = FileManager.default.fileExists(atPath: cloneLog)
        do {
            try cloneFile(clone, to: path + aside)
            if logs { try cloneFile(cloneLog, to: log + aside) }
            try move(path + aside, over: path)
        } catch {
            for file in [path + aside, log + aside] { FileManager.default.removeIfAny(URL(fileURLWithPath: file)) }
            throw error
        }
        if logs { try move(log + aside, over: log) } else { FileManager.default.removeIfAny(URL(fileURLWithPath: log)) }
    }

    /// Renames `file` over `target` in one step.
    private static func move(_ file: String, over target: String) throws {
        guard rename(file, target) == 0 else {
            throw DatabaseFailure.failed("\(target) couldn't be replaced (\(String(cString: strerror(errno)))).")
        }
    }
}
