import Core
import Foundation
import GRDB
import os

/// A project's settings for one database (the `database` table). It holds a database added by hand, or what the user
/// changed on a found one (what agents may do, production). Keyed by project and name.
struct SavedDatabase: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "database"
    var id: String, repoId: String, byHand: Bool, json: String

    var database: DatabaseInfo? {
        Log.store.attempt("reading the saved database \(id)") {
            try JSONDecoder().decode(DatabaseInfo.self, from: Data(json.utf8))
        }
    }

    /// `copyIn` is the workspace in whose files a branch's copy was found. The copy then keeps its settings apart from
    /// the project's database of the same name, under the key "<project>/<name>@<workspace>".
    init(repoId: String, database: DatabaseInfo, byHand: Bool, copyIn worktreeId: String? = nil) throws {
        id = repoId + "/" + database.name + (worktreeId.map { "@" + $0 } ?? "")
        self.repoId = repoId
        self.byHand = byHand
        json = String(decoding: try JSONEncoder().encode(database), as: UTF8.self)
    }
}

/// Answers db.*: a project's databases, found in its files or added by hand, and what was run on them lately, and by
/// whom. Every statement runs here, so no password reaches an agent. What agents may do is set per database
/// (`agentAccess`). A read runs in a read-only transaction. A change that has to ask first runs as a trial that is
/// rolled back, to say what it would change. Then it waits for the user's Allow on the agent's row (the same question
/// a permission dialog raises, in the banner, the Dock and the sidebar).
final class Databases: Sendable {
    let store: Store, watches: Watches, remotes: Remotes, offloads: Slots
    /// The parts of Sessions that databases need: the settings, who asks (an agent waits for the user's Allow on its
    /// row), and the port forward for a remote database.
    let settings: SettingsStore, live: SessionTable, permissions: PermissionWaits, processes: SessionProcesses
    let clients: Clients
    /// How many runs are kept per workspace (newest first), and how many of the latest runs keep their rows.
    static let keptRuns = 100, keptResults = 30
    /// How much of a result is kept and sent to an agent: a cell up to 16 KB, and the rows up to 1 MB in all.
    /// `keptWorkspaces` is how many workspaces keep their runs, the most recent ones.
    static let keptCell = 16 << 10, keptBytes = 1 << 20, keptWorkspaces = 20

    private struct Kept {
        var runs: [DatabaseRun] = []
        var results: [String: QueryResult] = [:]
    }
    private let kept = OSAllocatedUnfairLock(initialState: [String: Kept]())
    /// The addresses from projects' files (`fromTheFiles`) that the user has opened since kelpd started. Agents reach
    /// only those.
    private let opened = OSAllocatedUnfairLock(initialState: Set<String>())
    /// A remote project's databases as its host's files listed them, and when they were read. They are read again
    /// after a minute.
    private let onHosts = OSAllocatedUnfairLock(initialState: [String: (at: Date, found: [FoundDatabase])]())

    init(store: Store, sessions: Sessions, watches: Watches, remotes: Remotes, offloads: Slots) {
        self.store = store
        settings = sessions.settings
        live = sessions.live
        permissions = sessions.permissions
        processes = sessions.processes
        clients = sessions.clients
        self.watches = watches
        self.remotes = remotes
        self.offloads = offloads
    }

    // MARK: Which

    /// Returns the workspace's databases with their passwords: those found in its folder, and those changed or added
    /// by hand in its project.
    func connections(_ worktreeId: String) throws -> [DatabaseConnection] {
        guard let worktree = try store.worktree(worktreeId) else {
            throw RPCError.noWorkspace(worktreeId)
        }
        let host = remotes.of(worktree.path), remote = host != nil
        var found = host.map { onHost($0, worktreeId) } ?? DatabaseFind.find(in: worktree.path)
        // A branch's workspace has its project's databases too (an untracked SQLite file stays in the project's
        // folder), until it has a copy of its own (`copy`).
        if !remote, let project = try store.repo(worktree.repoId)?.path, project != worktree.path {
            let mine = Set(found.map(\.database.name))
            found += DatabaseFind.find(in: project).filter { !mine.contains($0.database.name) }.map { item in
                var item = item
                item.root = project
                return item
            }
        }
        let saved = try store.db.read {
            try SavedDatabase.filter(Column("repoId") == worktree.repoId).fetchAll($0)
        }
        var all = found.map { item -> DatabaseConnection in
            var db = item.database
            // What the user set for the database holds while it stays at the same place. A pulled .env that aims `app`
            // at another host makes a new database, which is read-only for agents again if it isn't on this Mac.
            let said = saved.lazy.filter { !$0.byHand }.compactMap(\.database)
            if let mine = said.first(where: { $0.name == db.name && $0.place == db.place }) {
                db.access = mine.access
                db.production = mine.production
                db.environment = mine.environment
                db.copy = mine.copy
            } else if !DatabaseFind.isRemote(db) {
                db.access = DatabaseInfo.Access(rawValue: settings[SettingKeys.databaseAccess]) ?? .ask
            }
            let container = item.service.flatMap { service in
                db.source.map {
                    ComposeService(
                        file: ((item.root ?? worktree.path) as NSString).appendingPathComponent($0), name: service.name,
                        port: service.port)
                }
            }
            return DatabaseConnection(database: db, password: item.password, container: remote ? nil : container)
        }
        for entry in saved where entry.byHand {
            guard let db = entry.database, !all.contains(where: { $0.database.name == db.name }) else { continue }
            let account = Self.account(entry.id)
            all.append(
                DatabaseConnection(database: db, password: Keychain.get(account), account: account, origin: .project))
        }
        // Another workspace's copy of a database belongs to that workspace: it isn't listed here unless it is in the
        // project's folder or was added by hand
        all.removeAll { $0.database.copy.map { $0.worktreeId != worktreeId } ?? false }
        return all
    }

    static func account(_ id: String) -> String { "db:" + id }

    /// Returns the keychain items of a project's saved databases, which are forgotten with the project (its rows go
    /// by cascade).
    func accounts(ofRepo repoId: String) throws -> [String] {
        try store.db.read { try SavedDatabase.filter(Column("repoId") == repoId).fetchAll($0) }.map {
            Self.account($0.id)
        }
    }

    /// Returns a remote project's databases, from its files read on the host in one go over the shared connection. It
    /// never dials, so with no connection open it returns what was read last (or nothing). SQLite files there aren't
    /// looked for.
    private func onHost(_ remote: RemoteHost, _ worktreeId: String) -> [FoundDatabase] {
        let last = onHosts.withLock { $0[worktreeId] }
        if let last, Date().timeIntervalSince(last.at) < 60 { return last.found }
        guard remote.connection != nil else { return last?.found ?? [] }
        guard
            let printed = Subprocess.printed(
                [remote.ssh] + remote.sshArgs(tty: false) + [DatabaseFind.remoteScript(remote.path)],
                path: "/usr/bin:/bin", timeout: 20)
        else {
            Log.store.error("reading \(remote.host)'s project files for its databases failed")
            return last?.found ?? []
        }
        let found = DatabaseFind.parse(remote: printed, root: remote.path)
        onHosts.withLock { $0[worktreeId] = (Date(), found) }
        return found
    }

    /// Returns where this Mac reaches the database. A server behind an SSH host (`ssh`), or a remote project's server,
    /// is reached through a port forwarded over the shared connection (as a page's port is, `Forwards`), which dials
    /// when there is no connection yet. Anything else is reached as it is.
    func reach(_ databaseConnection: DatabaseConnection, _ worktreeId: String) throws -> DatabaseConnection {
        let borrowed = try borrowPassword(databaseConnection)
        guard !borrowed.database.engine.isFile, let host = borrowed.database.host, let port = borrowed.database.port
        else { return borrowed }
        let through = try borrowed.database.ssh.map { ssh in
            guard RemoteHost.isHost(ssh) else { throw RPCError.invalidParams("\(ssh) isn't an SSH host's name.") }
            return remotes.host(ssh, path: "/")
        }
        // A database listed under All My Projects belongs to the user, not to the remote project's host.
        let project = borrowed.origin == .library ? nil : try store.worktree(worktreeId).flatMap { remotes.of($0.path) }
        guard let remote = through ?? project else { return borrowed }
        let here = try processes.forwards.forward("\(host):\(port)", in: worktreeId, remote)
        var near = borrowed
        near.database.host = "localhost"
        near.database.port = here
        return near
    }

    /// Reads a password still kept in another app's keychain (`passwordIn`), now that it is needed (macOS asks once),
    /// and keeps it in Kelp's own keychain so the next connection doesn't ask.
    func borrowPassword(_ databaseConnection: DatabaseConnection) throws -> DatabaseConnection {
        guard databaseConnection.password == nil, let item = databaseConnection.database.passwordIn else {
            return databaseConnection
        }
        var near = databaseConnection
        do { near.password = try ImportReaders.borrowed(item) } catch is KeychainDenied {
            throw DatabaseFailure.failed(
                "macOS didn't let Kelp read \(databaseConnection.database.name)'s password where it was imported from: type it in Edit…."
            )
        }
        if let password = near.password, let account = databaseConnection.account {
            Log.store.attempt("keeping \(databaseConnection.database.name)'s password") {
                try Keychain.set(password, account: account)
            }
        }
        return near
    }

    /// Returns the database named `name`, as the caller may see it. With `agent`, a hidden database and those in "All
    /// my projects" aren't found.
    func connection(_ worktreeId: String, _ name: String, agent: Bool) throws -> DatabaseConnection {
        let all = try connections(worktreeId).filter { !agent || $0.database.agentAccess != .hidden }
        if let one = all.first(where: { $0.database.name == name }) {
            guard try fromTheFiles(one.database, worktreeId) else { return one }
            let place = one.database.place
            if !agent {
                opened.withLock { _ = $0.insert(place) }
            } else if !opened.withLock({ $0.contains(place) }) {
                // A cloned repo's .env can name any host, so an agent's call doesn't make kelpd dial it
                throw RPCError.refused(
                    "\(name) is at \(one.database.host ?? "?"), an address from the project's files: Kelp connects "
                        + "there once the user opens it in Kelp's Databases.")
            }
            return one
        }
        if !agent, let mine = try libraryConnection(name) { return mine }
        let names = all.map(\.database.name).joined(separator: ", ")
        throw RPCError.invalidParams(
            all.isEmpty ? "This project has no databases Kelp knows of." : "No database \(name). There are: \(names).")
    }

    /// Whether the database's address comes from a project's files and is none of these: this Mac, a server behind the
    /// user's SSH host, or the remote project's own host. Such an address is one the user hasn't been asked about.
    private func fromTheFiles(_ db: DatabaseInfo, _ worktreeId: String) throws -> Bool {
        guard db.source != nil, db.ssh == nil, !db.engine.isFile, let host = db.host, !DatabaseInfo.isLocal(host)
        else { return false }
        return try store.worktree(worktreeId).flatMap { remotes.of($0.path) } == nil
    }

    func save(_ worktreeId: String, _ database: DatabaseInfo, password: String?, library: Bool = false) throws
        -> DatabaseInfo
    {
        if library { return try saveInLibrary(worktreeId, database, password: password) }
        guard let worktree = try store.worktree(worktreeId) else {
            throw RPCError.noWorkspace(worktreeId)
        }
        let name = database.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { throw RPCError.invalidParams("Give it a name without /.") }
        var db = database
        db.name = name
        let found = try connections(worktreeId).first { $0.database.name == name && $0.database.source != nil }
        if found != nil, database.source == nil {   // a database added by hand can't take a found database's name
            throw RPCError.invalidParams("Kelp found a database named \(name) already: give this one another name.")
        }
        if let found {   // a found database keeps its place; only access, production and environment change
            let access = db.access, production = db.production, environment = db.environment
            db = found.database
            db.access = access
            db.production = production
            db.environment = environment
        }
        // A branch's copy found among its files keeps its own settings, so the project's settings for that name aren't
        // written over
        let entry = try SavedDatabase(
            repoId: worktree.repoId, database: db, byHand: found == nil,
            copyIn: found?.database.copy.map(\.worktreeId))
        try store.db.write { try entry.save($0) }
        if found == nil, let password {
            if password.isEmpty {
                Keychain.delete(Self.account(entry.id))
            } else {
                try Keychain.set(password, account: Self.account(entry.id))
            }
        }
        touch(worktreeId)
        return db
    }

    func remove(_ worktreeId: String, _ name: String, library: Bool = false) throws {
        if library {
            _ = try store.db.write { try LibraryDatabase.deleteOne($0, key: name) }
            Keychain.delete(Self.libraryAccount(name))
        } else {
            guard let repo = try store.worktree(worktreeId)?.repoId else { return }
            let id = repo + "/" + name
            _ = try store.db.write { try SavedDatabase.deleteOne($0, key: id) }
            Keychain.delete(Self.account(id))
        }
        touch(worktreeId)
    }

    // MARK: What ran

    func activity(_ worktreeId: String) throws -> DatabasesEvent {
        DatabasesEvent(
            worktree: worktreeId, databases: try connections(worktreeId).map(\.database),
            runs: kept.withLock { $0[worktreeId]?.runs ?? [] }, library: try library())
    }

    func result(_ worktreeId: String, _ id: String) -> QueryResult? {
        kept.withLock { $0[worktreeId]?.results[id] }
    }

    func note(_ worktreeId: String, _ run: DatabaseRun, result: QueryResult? = nil) {
        kept.withLock { all in
            var mine = all[worktreeId] ?? Kept()
            if let index = mine.runs.firstIndex(where: { $0.id == run.id }) {
                mine.runs[index] = run
            } else {
                mine.runs.insert(run, at: 0)
                if mine.runs.count > Self.keptRuns { mine.runs.removeLast(mine.runs.count - Self.keptRuns) }
            }
            if let result {
                mine.results[run.id] = result
                // The latest results are not pushed out, nor a trial's results while its question is open (the trial's
                // rows are the change's)
                let latest = mine.runs.filter { mine.results[$0.id] != nil }.prefix(Self.keptResults).map(\.id)
                let keep = Set(latest + mine.runs.filter { $0.state == .asks }.map(\.id))
                mine.results = mine.results.filter { keep.contains($0.key) }
            }
            all[worktreeId] = mine
            if all.count > Self.keptWorkspaces {   // drop the workspace whose latest run is oldest
                let oldest = all.min {
                    ($0.value.runs.first?.at ?? .distantPast) < ($1.value.runs.first?.at ?? .distantPast)
                }
                if let oldest, oldest.key != worktreeId { all[oldest.key] = nil }
            }
        }
        touch(worktreeId)
    }

    func touch(_ worktreeId: String) {
        watches.touched(.init(topic: .databases, key: worktreeId), tag: UUID().uuidString)
    }
}
