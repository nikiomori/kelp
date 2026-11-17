import Core
import Foundation
import GRDB

/// Copies of a project's database made for a branch's workspace. A SQLite or DuckDB file is copied into the
/// workspace's folder, and a Postgres database on this Mac becomes a new database. The copy records which workspace
/// owns it (`DatabaseInfo.copy`). It is listed in that workspace only, agents change it without asking (because it can
/// be made again), and it is dropped with the workspace or by hand.
extension Databases {
    /// Makes a copy for the workspace's branch (`DatabaseCopy`) and returns the copy as it is listed now.
    func copy(_ worktreeId: String, _ name: String) async throws -> DatabaseInfo {
        guard let worktree = try store.worktree(worktreeId) else {
            throw RPCError.noWorkspace(worktreeId)
        }
        guard remotes.of(worktree.path) == nil else {
            throw RPCError.invalidParams("A remote project's databases stay on its host: Kelp copies them only here.")
        }
        let source = try await offloads.run { [self] in try connection(worktreeId, name, agent: false) }
        let suffix = Self.slug(worktree.branch)
        guard !source.database.production else {
            throw RPCError.invalidParams("\(name) is production: Kelp doesn't copy it.")
        }
        switch source.database.engine {
        case .sqlite, .duckdb:
            return try await offloads.run { [self] in try copyFile(source, worktree, suffix: suffix) }
        case .postgres:
            // Behind an SSH host, "localhost" means that host, not this Mac
            guard let host = source.database.host, DatabaseInfo.isLocal(host), source.database.ssh == nil,
                let database = source.database.database
            else {
                throw RPCError.invalidParams(
                    "Kelp copies a Postgres on this Mac that publishes its port; \(name) doesn't.")
            }
            // Reach the source as a query would, so a password still in another app's keychain is read now
            let near = try await offloads.run { [self] in try reach(source, worktreeId) }
            let copied = database + "_" + suffix, pg = DatabaseInfo.Engine.postgres
            var maintenance = near   // nobody may be connected to a template, this connection included
            maintenance.database.database = "postgres"
            do {
                _ = try await DatabaseEngines.write(
                    maintenance, "CREATE DATABASE \(pg.quoted(copied)) TEMPLATE \(pg.quoted(database))", off: offloads)
            } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
            var db = Self.asCopy(source.database, of: name, for: worktreeId)
            db.name = name + "_" + suffix
            db.database = copied
            db.source = nil
            let password = near.password, kept = db
            do { return try await offloads.run { [self] in try save(worktreeId, kept, password: password) } } catch {
                // The copy wasn't saved, so it is dropped, or the next copy would fail with "already exists"
                do {
                    _ = try await DatabaseEngines.write(
                        maintenance, "DROP DATABASE \(pg.quoted(copied))", off: offloads)
                } catch { Log.store.error("dropping \(copied) after its save failed: \(error)") }
                throw error
            }
        case .mysql, .appwrite:
            throw RPCError.invalidParams("Kelp copies SQLite files and Postgres databases, not \(name)'s engine.")
        }
    }

    /// Copies a file database into the branch's folder at the same relative place when the file is inside the project;
    /// otherwise beside the original, with the branch's name added.
    fileprivate func copyFile(_ databaseConnection: DatabaseConnection, _ worktree: Worktree, suffix: String) throws
        -> DatabaseInfo
    {
        guard let path = databaseConnection.database.path else {
            throw RPCError.invalidParams("\(databaseConnection.database.name) has no file.")
        }
        let project = try store.repo(worktree.repoId)?.path ?? worktree.path
        let target: String
        // Compare and cut the real paths, because a project reached through a link has the same file at another path
        let (real, realProject) = (Paths.realNearest(path), Paths.realNearest(project))
        if Paths.inside(path, project), !Paths.inside(path, worktree.path), real.hasPrefix(realProject + "/") {
            target = worktree.path + real.dropFirst(realProject.count)
        } else {
            let ext = (path as NSString).pathExtension, base = (path as NSString).deletingPathExtension
            target = base + "_" + suffix + (ext.isEmpty ? "" : "." + ext)
        }
        guard !FileManager.default.fileExists(atPath: target) else {
            throw RPCError.invalidParams("There's a copy already: \(target).")
        }
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var made = false
        do {
            if databaseConnection.database.engine == .duckdb {
                // DuckDB keeps one file, with no -wal. A file already there is another copy, and any other failure
                // leaves half of ours
                do { try FileManager.default.copyItem(atPath: path, toPath: target) } catch CocoaError
                    .fileWriteFileExists
                {
                    throw RPCError.invalidParams("There's a copy already: \(target).")
                } catch {
                    made = true
                    throw error
                }
            } else {
                // Create the file here or refuse, so two copies asked for at once don't back up into one file (the
                // check above can't tell). In the DuckDB branch, copyItem itself refuses a file that is already there.
                let created = open(target, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                guard created >= 0 else { throw RPCError.invalidParams("There's a copy already: \(target).") }
                close(created)
                made = true
                try SQLiteRun.copy(path, to: target)
            }
        } catch {
            // A copy that failed half way (a full disk) isn't left to be found as the branch's database
            if made { Self.removeCopy(target) }
            if let failure = error as? DatabaseFailure { throw RPCError.invalidParams(failure.message) }
            throw error
        }
        // In a place where Kelp looks (the top, db/, …), the copy is found like any file there, and the note that it
        // is a copy is kept beside the project's settings for the database of that name. Anywhere else, the copy is
        // kept as a database added by hand.
        if let found = try connections(worktree.id).first(where: { $0.database.path == target }) {
            var db = Self.asCopy(found.database, of: databaseConnection.database.name, for: worktree.id)
            if databaseConnection.database.access == .hidden { db.access = .hidden }
            let entry = try SavedDatabase(repoId: worktree.repoId, database: db, byHand: false, copyIn: worktree.id)
            try store.db.write { try entry.save($0) }
            touch(worktree.id)
            return db
        }
        var db = DatabaseInfo(
            name: databaseConnection.database.name + "_" + suffix, engine: databaseConnection.database.engine,
            path: target)
        db = Self.asCopy(db, of: databaseConnection.database.name, for: worktree.id)
        db.access = databaseConnection.database.access == .hidden ? .hidden : .free
        return try save(worktree.id, db, password: nil)
    }

    /// Marks `db` as a workspace's copy of `name`. Agents change the copy without asking, unless the original is
    /// hidden from them.
    static func asCopy(_ db: DatabaseInfo, of name: String, for worktreeId: String) -> DatabaseInfo {
        var copy = db
        copy.copy = BranchCopy(of: name, worktreeId: worktreeId, at: Date())
        copy.access = db.access == .hidden ? .hidden : .free
        copy.production = false
        return copy
    }

    /// Drops the workspace's copy `name` (`DatabaseCopyRemove`): its file, or its Postgres database, and what Kelp
    /// keeps of it.
    func dropCopy(_ worktreeId: String, _ name: String) async throws {
        let c = try await offloads.run { [self] in try connection(worktreeId, name, agent: false) }
        guard c.database.copy?.worktreeId == worktreeId, let repo = try store.worktree(worktreeId)?.repoId else {
            throw RPCError.invalidParams("\(name) isn't this workspace's copy of a database.")
        }
        do {
            if c.database.engine.isFile {
                if let path = c.database.path { Self.removeCopy(path) }
            } else {
                try await dropDatabase(try await offloads.run { [self] in try reach(c, worktreeId) })
            }
        } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
        try forget(copy: c.database, byHand: c.origin == .project, repo: repo)
        touch(worktreeId)
    }

    /// Runs DROP DATABASE from the server's own `postgres` database, because nobody may be connected to the database
    /// being dropped.
    private func dropDatabase(_ databaseConnection: DatabaseConnection) async throws {
        guard databaseConnection.database.engine == .postgres, let database = databaseConnection.database.database
        else {
            throw DatabaseFailure.failed(
                "Kelp drops a copy that is a file or a Postgres database, not \(databaseConnection.database.name).")
        }
        var maintenance = databaseConnection
        maintenance.database.database = "postgres"
        _ = try await DatabaseEngines.write(
            maintenance, "DROP DATABASE IF EXISTS \(DatabaseInfo.Engine.postgres.quoted(database))", off: offloads)
    }

    /// Forgets what Kelp keeps of a copy. For a copy added by hand, that is its own entry and password. Otherwise it is
    /// the entry that marks the found file as a copy, and the project's settings for the database of that name stay.
    private func forget(copy db: DatabaseInfo, byHand: Bool, repo: String) throws {
        let id = repo + "/" + db.name + (byHand ? "" : "@" + (db.copy?.worktreeId ?? ""))
        _ = try store.db.write { try SavedDatabase.deleteOne($0, key: id) }
        if byHand { Keychain.delete(Self.account(id)) }
    }

    /// Drops the copies of a workspace that is gone. A file went with its folder. A Postgres database is dropped now
    /// (it is on this Mac, so there's no host to reach), and a failure goes to the log, because nobody is waiting.
    func dropCopies(of worktree: Worktree) {
        let saved: [SavedDatabase]
        do {
            saved = try store.db.read { try SavedDatabase.filter(Column("repoId") == worktree.repoId).fetchAll($0) }
        } catch {
            return Log.store.error("reading \(worktree.branch)'s database copies: \(error)")
        }
        for entry in saved {
            guard let db = entry.database, db.copy?.worktreeId == worktree.id else { continue }
            let connection = DatabaseConnection(
                database: db, password: entry.byHand ? Keychain.get(Self.account(entry.id)) : nil)
            Task { [self] in
                do {
                    if !db.engine.isFile { try await dropDatabase(connection) }
                    try forget(copy: db, byHand: entry.byHand, repo: worktree.repoId)
                } catch { Log.store.error("dropping \(db.name), \(worktree.branch)'s copy: \(error)") }
            }
        }
    }

    /// Removes a half-made copy and the files SQLite made beside it.
    static func removeCopy(_ target: String) {
        for file in [target, target + "-wal", target + "-shm", target + "-journal"]
        where FileManager.default.fileExists(atPath: file) {
            do { try FileManager.default.removeItem(atPath: file) } catch {
                Log.session.error("db copy: couldn't remove the half-made \(file): \(error)")
            }
        }
    }

    /// Turns a branch into the tail of a name, such as "fix/orders" → "fix_orders".
    static func slug(_ branch: String) -> String {
        let words = branch.lowercased().split { !($0.isLetter || $0.isNumber) }
        let slug = String(words.joined(separator: "_").prefix(30))
        return slug.isEmpty ? "copy" : slug
    }
}
