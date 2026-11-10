import Core
import Foundation
import GRDB

/// One of "All my projects" (`databaseLibrary` table), keyed by name.
struct LibraryDatabase: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "databaseLibrary"
    var id: String, json: String

    var database: DatabaseInfo? {
        Log.store.attempt("reading the library's database \(id)") {
            try JSONDecoder().decode(DatabaseInfo.self, from: Data(json.utf8))
        }
    }

    init(_ database: DatabaseInfo) throws {
        id = database.name
        json = String(decoding: try JSONEncoder().encode(database), as: UTF8.self)
    }
}

/// "All my projects": databases the user keeps apart from any project (added so, or imported from another app). No
/// agent sees one until it's used in a project (`use`), which copies it there. Their passwords are kept as
/// "db:/<name>". And what the Add Database sheet asks of the daemon: a check of what's typed, the servers running in
/// Docker.
extension Databases {
    /// Its password's keychain account: "db:/<name>", a project's with no project.
    static func libraryAccount(_ name: String) -> String { account("/" + name) }

    func library() throws -> [DatabaseInfo] {
        try store.db.read { try LibraryDatabase.fetchAll($0) }.compactMap(\.database)
            .sorted { ($0.group ?? "", $0.name) < ($1.group ?? "", $1.name) }
    }

    func libraryConnection(_ name: String) throws -> DatabaseConnection? {
        guard let entry = try store.db.read({ try LibraryDatabase.fetchOne($0, key: name) }), let db = entry.database
        else { return nil }
        let account = Self.libraryAccount(name)
        return DatabaseConnection(database: db, password: Keychain.get(account), account: account, origin: .library)
    }

    func saveInLibrary(_ worktreeId: String, _ database: DatabaseInfo, password: String?) throws -> DatabaseInfo {
        var db = database
        db.name = db.name.trimmingCharacters(in: .whitespaces)
        db.source = nil
        guard !db.name.isEmpty, !db.name.contains("/") else {
            throw RPCError.invalidParams("Give it a name without /.")
        }
        let entry = try LibraryDatabase(db)
        try store.db.write { try entry.save($0) }
        let account = Self.libraryAccount(db.name)
        if let password {
            if password.isEmpty { Keychain.delete(account) } else { try Keychain.set(password, account: account) }
        }
        touch(worktreeId)
        return db
    }

    /// Copied into the workspace's project with its password: from now on its agents see it.
    func use(_ worktreeId: String, _ name: String, access: DatabaseInfo.Access?) throws -> DatabaseInfo {
        guard let mine = try libraryConnection(name) else {
            throw RPCError.invalidParams("No \(name) in All my projects.")
        }
        var db = mine.database
        db.access = access ?? (db.host.map(DatabaseInfo.isLocal) == false ? .read : db.access)
        db.group = nil
        return try save(worktreeId, db, password: mine.password)
    }

    // MARK: The sheet's check

    func check(_ q: DatabaseCheck) async throws -> DatabaseCheckResult {
        let (wid, name) = (q.worktreeId, q.database.name)
        var given = DatabaseConnection(database: q.database, password: q.password)
        if given.password == nil {   // the one kept for it, when it's being edited
            given.password = try await offloads.run { [self] in
                do { return try connection(wid, name, agent: false).password } catch { return nil }
            }
        }
        let started = Date()
        let typed = given
        let near = try await offloads.run { [self] in try reach(typed, wid) }
        do {
            let all = q.versionOnly != true
            let tables = all ? try await DatabaseEngines.schema(near, table: nil, off: offloads).tables.count : 0
            let runner = DatabaseEngines.runner(near, off: offloads)
            let version = try await runner.version() ?? near.database.engine.displayName
            let databases = all ? try await runner.databases() : []
            return DatabaseCheckResult(
                version: version, tables: tables, databases: databases,
                ms: Int(Date().timeIntervalSince(started) * 1000))
        } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
    }
}

extension DatabaseCheck: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> DatabaseCheckResult { try await dbs.check(self) }
}

extension DatabaseContainers: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> [RunningDatabase] { try await dbs.containers() }
}

extension DatabaseUse: Handled {
    func handle(_ dbs: Databases) throws -> DatabaseInfo { try dbs.use(worktreeId, name, access: access) }
}
