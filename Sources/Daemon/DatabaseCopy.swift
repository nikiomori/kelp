import Core
import Foundation

/// A database of the project's copied for a branch's workspace: a SQLite or DuckDB file into its folder, a Postgres
/// database on this Mac as a new one.
extension Databases {
    /// A copy for the workspace's branch (`DatabaseCopy`): the copy as it's listed now.
    func copy(_ worktreeId: String, _ name: String) async throws -> DatabaseInfo {
        guard let worktree = try store.worktree(worktreeId) else {
            throw RPCError.invalidParams("No workspace \(worktreeId).")
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
            // Behind an SSH host, "localhost" is that host's: not this Mac's
            guard let host = source.database.host, DatabaseFind.isLocal(host), source.database.ssh == nil,
                let database = source.database.database
            else {
                throw RPCError.invalidParams(
                    "Kelp copies a Postgres on this Mac that publishes its port; \(name) doesn't.")
            }
            // Its password as a query would have it: one still in another app's keychain is read now
            let near = try await offloads.run { [self] in try reach(source, worktreeId) }
            let copied = database + "_" + suffix
            var maintenance = near   // a template can't have anyone connected, this connection included
            maintenance.database.database = "postgres"
            do {
                _ = try await DatabaseEngines.write(
                    maintenance, "CREATE DATABASE \(Self.quoted(copied)) TEMPLATE \(Self.quoted(database))",
                    off: offloads)
            } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
            var db = source.database
            db.name = name + "_" + suffix
            db.database = copied
            db.source = nil
            let password = near.password, kept = db
            do { return try await offloads.run { [self] in try save(worktreeId, kept, password: password) } } catch {
                // Not kept, so not left behind: the next copy would find it "already exists"
                do {
                    _ = try await DatabaseEngines.write(
                        maintenance, "DROP DATABASE \(Self.quoted(copied))", off: offloads)
                } catch { Log.store.error("dropping \(copied) after its save failed: \(error)") }
                throw error
            }
        case .mysql, .appwrite:
            throw RPCError.invalidParams("Kelp copies SQLite files and Postgres databases, not \(name)'s engine.")
        }
    }

    /// Into the branch's folder at the same place when it's the project's file, else beside it with the branch's name.
    fileprivate func copyFile(_ c: DatabaseConnection, _ worktree: Worktree, suffix: String) throws -> DatabaseInfo {
        guard let path = c.database.path else { throw RPCError.invalidParams("\(c.database.name) has no file.") }
        let project = try store.repo(worktree.repoId)?.path ?? worktree.path
        let target: String
        // Compared and cut as they really are: a project reached through a link has the same file at another path
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
            if c.database.engine == .duckdb {
                // DuckDB keeps one file, no -wal; one there already is another's copy, any other failure half of ours
                do { try FileManager.default.copyItem(atPath: path, toPath: target) } catch CocoaError
                    .fileWriteFileExists
                {
                    throw RPCError.invalidParams("There's a copy already: \(target).")
                } catch {
                    made = true
                    throw error
                }
            } else {
                // Made here or refused: two copies asked at once don't back up into one file (the check above can't
                // tell); copyItem refuses one that's there itself.
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
        touch(worktree.id)
        // Where Kelp looks (the top, db/, …) it's found as it is; anywhere else it's kept as one added by hand.
        if let found = try connections(worktree.id).first(where: { $0.database.path == target }) {
            return found.database
        }
        let db = DatabaseInfo(
            name: c.database.name + "_" + suffix, engine: c.database.engine, path: target, access: c.database.access)
        return try save(worktree.id, db, password: nil)
    }

    /// A half-made copy and what SQLite made beside it.
    static func removeCopy(_ target: String) {
        for file in [target, target + "-wal", target + "-shm", target + "-journal"]
        where FileManager.default.fileExists(atPath: file) {
            do { try FileManager.default.removeItem(atPath: file) } catch {
                Log.session.error("db copy: couldn't remove the half-made \(file): \(error)")
            }
        }
    }

    /// A branch as a name's tail: "fix/orders" → "fix_orders".
    static func slug(_ branch: String) -> String {
        let words = branch.lowercased().split { !($0.isLetter || $0.isNumber) }
        let slug = String(words.joined(separator: "_").prefix(30))
        return slug.isEmpty ? "copy" : slug
    }

    static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
