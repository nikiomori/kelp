import Core
import Foundation
import GRDB
import os

/// A project's settings for a database (`database` table): one added by hand, or what was changed of a found one (what
/// agents may do, production). Keyed by project and name.
struct SavedDatabase: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "database"
    var id: String, repoId: String, byHand: Bool, json: String

    var database: DatabaseInfo? {
        Log.store.attempt("reading the saved database \(id)") {
            try JSONDecoder().decode(DatabaseInfo.self, from: Data(json.utf8))
        }
    }

    init(repoId: String, database: DatabaseInfo, byHand: Bool) throws {
        id = repoId + "/" + database.name
        self.repoId = repoId
        self.byHand = byHand
        json = String(decoding: try JSONEncoder().encode(database), as: UTF8.self)
    }
}

/// db.*: a project's databases, found in its files or added by hand, and what was run on them lately, by whom. Every
/// statement runs here, so no password reaches an agent. What agents may do is each database's `agentAccess`: a read
/// runs in a read-only transaction, a change that asks waits for the user's Allow on the agent's row (the same question
/// a permission dialog asks: banner, Dock, sidebar), after a trial that was rolled back says what it would change.
final class Databases: Sendable {
    let store: Store, sessions: Sessions, watches: Watches, remotes: Remotes, offloads: Slots
    /// Runs kept per workspace (newest first), and the rows of the latest of them.
    static let keptRuns = 100, keptResults = 30
    /// What's kept of a result, and sent to an agent: a cell to 16 KB, the rows to 1 MB in all; the workspaces whose
    /// runs are kept, the latest.
    static let keptCell = 16 << 10, keptBytes = 1 << 20, keptWorkspaces = 20

    private struct Kept {
        var runs: [DatabaseRun] = []
        var results: [String: QueryResult] = [:]
    }
    private let kept = OSAllocatedUnfairLock(initialState: [String: Kept]())
    /// The addresses from projects' files (`fromTheFiles`) the user has opened since kelpd started: agents reach only
    /// those.
    private let opened = OSAllocatedUnfairLock(initialState: Set<String>())
    /// A remote project's databases as its host's files said them, and when: read again after a minute.
    private let onHosts = OSAllocatedUnfairLock(initialState: [String: (at: Date, found: [FoundDatabase])]())

    init(store: Store, sessions: Sessions, watches: Watches, remotes: Remotes, offloads: Slots) {
        self.store = store
        self.sessions = sessions
        self.watches = watches
        self.remotes = remotes
        self.offloads = offloads
    }

    // MARK: Which

    /// The workspace's databases with their passwords: found in its folder, changed or added by hand in its project.
    func connections(_ worktreeId: String) throws -> [DatabaseConnection] {
        guard let worktree = try store.worktree(worktreeId) else {
            throw RPCError.invalidParams("No workspace \(worktreeId).")
        }
        let host = remotes.of(worktree.path), remote = host != nil
        var found = host.map { onHost($0, worktreeId) } ?? DatabaseFind.find(in: worktree.path)
        // A branch's workspace has its project's databases too (an untracked SQLite file stays in the project's folder),
        // until it has a copy of its own (`copy`).
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
            // What the user said of it holds while it's the same place: a pulled .env that aims `app` at another host
            // is a new database, read only for agents again if it isn't this Mac.
            if let mine = saved.first(where: { !$0.byHand && $0.database?.name == db.name })?.database,
                mine.place == db.place
            {
                db.access = mine.access
                db.production = mine.production
                db.environment = mine.environment
            } else if !DatabaseFind.isRemote(db) {
                db.access = DatabaseInfo.Access(rawValue: sessions.settings[SettingKeys.databaseAccess]) ?? .ask
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
        return all
    }

    static func account(_ id: String) -> String { "db:" + id }

    /// The keychain items of a project's saved databases: forgotten with the project (its rows go by cascade).
    func accounts(ofRepo repoId: String) throws -> [String] {
        try store.db.read { try SavedDatabase.filter(Column("repoId") == repoId).fetchAll($0) }.map {
            Self.account($0.id)
        }
    }

    /// A remote project's databases, from its files read on the host in one go over the shared connection. Never dials:
    /// with no connection open, what was read last (or nothing). SQLite files there aren't looked for.
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

    /// Where this Mac reaches it: a server behind an SSH host (`ssh`), or a remote project's, through a port forwarded
    /// over the shared connection (as a page's port is, `Forwards`), which dials when there's none. Anything else as it
    /// is.
    func reach(_ c: DatabaseConnection, _ worktreeId: String) throws -> DatabaseConnection {
        let borrowed = try borrowPassword(c)
        guard !borrowed.database.engine.isFile, let host = borrowed.database.host, let port = borrowed.database.port
        else { return borrowed }
        let through = try borrowed.database.ssh.map { ssh in
            guard RemoteHost.isHost(ssh) else { throw RPCError.invalidParams("\(ssh) isn't an SSH host's name.") }
            return remotes.host(ssh, path: "/")
        }
        // One of All My Projects is the user's, not the remote project's host's.
        let project = borrowed.origin == .library ? nil : try store.worktree(worktreeId).flatMap { remotes.of($0.path) }
        guard let remote = through ?? project else { return borrowed }
        let here = try sessions.processes.forwards.forward("\(host):\(port)", in: worktreeId, remote)
        var near = borrowed
        near.database.host = "localhost"
        near.database.port = here
        return near
    }

    /// A password still in another app's keychain (`passwordIn`), read now that it's needed (macOS asks, once) and
    /// kept in Kelp's own: the next connection doesn't ask.
    func borrowPassword(_ c: DatabaseConnection) throws -> DatabaseConnection {
        guard c.password == nil, let item = c.database.passwordIn else { return c }
        var near = c
        do { near.password = try ImportReaders.borrowed(item) } catch is KeychainDenied {
            throw DatabaseFailure.failed(
                "macOS didn't let Kelp read \(c.database.name)'s password where it was imported from: type it in Edit…."
            )
        }
        if let password = near.password, let account = c.account {
            Log.store.attempt("keeping \(c.database.name)'s password") { try Keychain.set(password, account: account) }
        }
        return near
    }

    /// The one named `name`, as `caller` may see it: an agent isn't told of a hidden one, nor of "All my projects".
    func connection(_ worktreeId: String, _ name: String, agent: Bool) throws -> DatabaseConnection {
        let all = try connections(worktreeId).filter { !agent || $0.database.agentAccess != .hidden }
        if let one = all.first(where: { $0.database.name == name }) {
            guard try fromTheFiles(one.database, worktreeId) else { return one }
            let place = one.database.place
            if !agent {
                opened.withLock { _ = $0.insert(place) }
            } else if !opened.withLock({ $0.contains(place) }) {
                // A cloned repo's .env can name any host: an agent's call doesn't make kelpd dial it
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

    /// An address a project's files name that isn't this Mac, a server behind the user's SSH host or the remote
    /// project's own host: one the user hasn't been asked about.
    private func fromTheFiles(_ db: DatabaseInfo, _ worktreeId: String) throws -> Bool {
        guard db.source != nil, db.ssh == nil, !db.engine.isFile, let host = db.host, !DatabaseInfo.isLocal(host)
        else { return false }
        return try store.worktree(worktreeId).flatMap { remotes.of($0.path) } == nil
    }

    func save(_ worktreeId: String, _ database: DatabaseInfo, password: String?) throws -> DatabaseInfo {
        try save(worktreeId, database, password: password, library: false)
    }

    func save(_ worktreeId: String, _ database: DatabaseInfo, password: String?, library: Bool) throws -> DatabaseInfo {
        if library { return try saveInLibrary(worktreeId, database, password: password) }
        guard let worktree = try store.worktree(worktreeId) else {
            throw RPCError.invalidParams("No workspace \(worktreeId).")
        }
        let name = database.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { throw RPCError.invalidParams("Give it a name without /.") }
        var db = database
        db.name = name
        let found = try connections(worktreeId).first { $0.database.name == name && $0.database.source != nil }
        if found != nil, database.source == nil {   // one added by hand can't take a found one's name
            throw RPCError.invalidParams("Kelp found a database named \(name) already: give this one another name.")
        }
        if let found {   // a found one keeps where it is; only what agents may do changes
            let access = db.access, production = db.production, environment = db.environment
            db = found.database
            db.access = access
            db.production = production
            db.environment = environment
        }
        let entry = try SavedDatabase(repoId: worktree.repoId, database: db, byHand: found == nil)
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
                // The latest results, and a trial's while it's asked (its rows are the change's): not pushed out
                let latest = mine.runs.filter { mine.results[$0.id] != nil }.prefix(Self.keptResults).map(\.id)
                let keep = Set(latest + mine.runs.filter { $0.state == .asks }.map(\.id))
                mine.results = mine.results.filter { keep.contains($0.key) }
            }
            all[worktreeId] = mine
            if all.count > Self.keptWorkspaces {   // the one whose latest run is oldest goes
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
