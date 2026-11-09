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

    private struct Kept {
        var runs: [DatabaseRun] = []
        var results: [String: QueryResult] = [:]
    }
    private let kept = OSAllocatedUnfairLock(initialState: [String: Kept]())
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
            if let mine = saved.first(where: { !$0.byHand && $0.database?.name == db.name })?.database {
                db.access = mine.access
                db.production = mine.production
            } else if !db.production {
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
            all.append(DatabaseConnection(database: db, password: Keychain.get(Self.account(entry.id))))
        }
        return all
    }

    static func account(_ id: String) -> String { "db:" + id }

    /// A remote project's databases, from its files read on the host in one go over the shared connection. Never dials:
    /// with no connection open, what was read last (or nothing). SQLite files there aren't looked for.
    private func onHost(_ remote: RemoteHost, _ worktreeId: String) -> [FoundDatabase] {
        let last = onHosts.withLock { $0[worktreeId] }
        if let last, Date().timeIntervalSince(last.at) < 60 { return last.found }
        guard remote.connection != nil,
            let printed = Subprocess.printed(
                [remote.ssh] + remote.sshArgs(tty: false) + [DatabaseFind.remoteScript(remote.path)],
                path: "/usr/bin:/bin", timeout: 20)
        else { return last?.found ?? [] }
        let found = DatabaseFind.parse(remote: printed, root: remote.path)
        onHosts.withLock { $0[worktreeId] = (Date(), found) }
        return found
    }

    /// Where this Mac reaches it: a server behind an SSH host (`ssh`), or a remote project's, through a port forwarded
    /// over the shared connection (as a page's port is, `Forwards`), which dials when there's none. Anything else as it
    /// is.
    func reach(_ c: DatabaseConnection, _ worktreeId: String) throws -> DatabaseConnection {
        guard !c.database.engine.isFile, let host = c.database.host, let port = c.database.port else { return c }
        let through = try c.database.ssh.map { ssh in
            guard RemoteHost.isHost(ssh) else { throw RPCError.invalidParams("\(ssh) isn't an SSH host's name.") }
            return remotes.host(ssh, path: "/")
        }
        guard let remote = try through ?? store.worktree(worktreeId).flatMap({ remotes.of($0.path) }) else { return c }
        let here = try sessions.processes.forwards.forward("\(host):\(port)", in: worktreeId, remote)
        var near = c
        near.database.host = "localhost"
        near.database.port = here
        return near
    }

    /// The one named `name`, as `caller` may see it: an agent isn't told of a hidden one, nor of "All my projects".
    func connection(_ worktreeId: String, _ name: String, agent: Bool) throws -> DatabaseConnection {
        let all = try connections(worktreeId).filter { !agent || $0.database.agentAccess != .hidden }
        if let one = all.first(where: { $0.database.name == name }) { return one }
        if !agent, let mine = try libraryConnection(name) { return mine }
        let names = all.map(\.database.name).joined(separator: ", ")
        throw RPCError.invalidParams(
            all.isEmpty ? "This project has no databases Kelp knows of." : "No database \(name). There are: \(names).")
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
            let access = db.access, production = db.production
            db = found.database
            db.access = access
            db.production = production
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

    /// A copy for the workspace's branch (`DatabaseCopy`): the copy as it's listed now.
    func copy(_ worktreeId: String, _ name: String) async throws -> DatabaseInfo {
        guard let worktree = try store.worktree(worktreeId) else {
            throw RPCError.invalidParams("No workspace \(worktreeId).")
        }
        guard remotes.of(worktree.path) == nil else {
            throw RPCError.invalidParams("A remote project's databases stay on its host: Kelp copies them only here.")
        }
        let c = try await offloads.run { [self] in try connection(worktreeId, name, agent: false) }
        let suffix = Self.slug(worktree.branch)
        guard !c.database.production else {
            throw RPCError.invalidParams("\(name) is production: Kelp doesn't copy it.")
        }
        switch c.database.engine {
        case .sqlite, .duckdb: return try await offloads.run { [self] in try copyFile(c, worktree, suffix: suffix) }
        case .postgres:
            guard let host = c.database.host, DatabaseFind.isLocal(host), let database = c.database.database else {
                throw RPCError.invalidParams(
                    "Kelp copies a Postgres on this Mac that publishes its port; \(name) doesn't.")
            }
            let copied = database + "_" + suffix
            var maintenance = c   // a template can't have anyone connected, this connection included
            maintenance.database.database = "postgres"
            do {
                _ = try await DatabaseEngines.write(
                    maintenance, "CREATE DATABASE \(Self.quoted(copied)) TEMPLATE \(Self.quoted(database))",
                    off: offloads)
            } catch let failure as DatabaseFailure { throw RPCError.invalidParams(failure.message) }
            var db = c.database
            db.name = name + "_" + suffix
            db.database = copied
            db.source = nil
            return try save(worktreeId, db, password: c.password)
        case .mysql: throw RPCError.invalidParams("Kelp copies SQLite files and Postgres databases, not MySQL's.")
        }
    }

    /// Into the branch's folder at the same place when it's the project's file, else beside it with the branch's name.
    private func copyFile(_ c: DatabaseConnection, _ worktree: Worktree, suffix: String) throws -> DatabaseInfo {
        guard let path = c.database.path else { throw RPCError.invalidParams("\(c.database.name) has no file.") }
        let project = try store.repo(worktree.repoId)?.path ?? worktree.path
        let target: String
        if path.hasPrefix(project + "/"), !path.hasPrefix(worktree.path + "/") {
            target = worktree.path + path.dropFirst(project.count)
        } else {
            let ext = (path as NSString).pathExtension, base = (path as NSString).deletingPathExtension
            target = base + "_" + suffix + (ext.isEmpty ? "" : "." + ext)
        }
        guard !FileManager.default.fileExists(atPath: target) else {
            throw RPCError.invalidParams("There's a copy already: \(target).")
        }
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do {
            if c.database.engine == .duckdb {
                try FileManager.default.copyItem(atPath: path, toPath: target)   // DuckDB keeps one file, no -wal
            } else {
                try SQLiteRun.copy(path, to: target)
            }
        } catch let failure as DatabaseFailure {
            throw RPCError.invalidParams(failure.message)
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

    /// A branch as a name's tail: "fix/orders" → "fix_orders".
    static func slug(_ branch: String) -> String {
        let words = branch.lowercased().split { !($0.isLetter || $0.isNumber) }
        let slug = String(words.joined(separator: "_").prefix(30))
        return slug.isEmpty ? "copy" : slug
    }

    static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    func remove(_ worktreeId: String, _ name: String, library: Bool = false) throws {
        guard let repo = library ? Self.libraryRepo : try store.worktree(worktreeId)?.repoId else { return }
        let id = repo + "/" + name
        _ = try store.db.write {
            try library ? LibraryDatabase.deleteOne($0, key: name) : SavedDatabase.deleteOne($0, key: id)
        }
        Keychain.delete(Self.account(id))
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

    private func note(_ worktreeId: String, _ run: DatabaseRun, result: QueryResult? = nil) {
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
                let keep = Set(mine.runs.prefix(Self.keptResults).map(\.id))
                mine.results = mine.results.filter { keep.contains($0.key) }
            }
            all[worktreeId] = mine
        }
        touch(worktreeId)
    }

    func touch(_ worktreeId: String) {
        watches.touched(.init(topic: .databases, key: worktreeId), tag: UUID().uuidString)
    }

    // MARK: Running

    /// Who asks, from the caller (`Sessions.asker`): nil for the user (Kelp's window, a terminal of the user's own);
    /// else the agent's session to ask, nil inside when there's none to ask (a program of kelpd's, one that left).
    func agent(origin: String?) -> String?? {
        guard let origin else { return .none }
        let session = Caller.session(of: origin)
        // A session that can't be read is held to an agent's rules, as the fence holds it.
        if let session, !Caller.typedOrigin(origin),
            Log.store.attempt("whether \(session) is an agent's", { try store.forAnAgent(session) }) == false
        {
            return .none
        }
        return .some(session)
    }

    func query(_ q: DatabaseQuery, origin: String?) async throws -> QueryResult {
        let asker = agent(origin: origin), forAgent = asker != nil
        let (wid, name) = (q.worktreeId, q.database)
        // Off the pool: a remote project's are read on its host, and reached through a forwarded port.
        let c = try await offloads.run { [self] in try reach(connection(wid, name, agent: forAgent), wid) }
        let sql: String
        do { sql = try SQLText.single(q.sql) } catch let failure as DatabaseFailure {
            throw RPCError.invalidParams(failure.message)
        }
        let id = UUID().uuidString, session = asker ?? nil
        var run = DatabaseRun(id: id, database: c.database.name, sql: sql, session: session, at: Date(), state: .done)
        let access = forAgent ? c.database.agentAccess : .free
        do {
            let started = Date()
            let timeout = max(1, sessions.settings[SettingKeys.databaseTimeout])
            let rows = try await DatabaseEngines.read(c, sql, timeout: timeout, off: offloads)
            return finish(q, &run, rows, started: started)
        } catch DatabaseFailure.change {
            switch access {
            case .hidden, .read:
                run.state = .refused
                run.error = "\(c.database.name) is read-only for agents."
                note(q.worktreeId, run)
                let others = try await offloads.run { [self] in
                    try connections(wid).filter { [.ask, .free].contains($0.database.agentAccess) }.map(\.database.name)
                }
                throw RPCError.refused(
                    "\(c.database.name) is read-only for agents: ask the user to run it"
                        + (others.isEmpty ? "." : ", or try it on \(others.joined(separator: " or ")).")
                )
            case .ask:
                guard try await allowed(q, c, sql, &run, session: session) else {
                    throw RPCError.refused(run.error ?? "The user didn't allow it.")
                }
                fallthrough
            case .free:
                let started = Date()
                do {
                    let rows = try await DatabaseEngines.write(c, sql, off: offloads)
                    run.state = .done
                    return finish(q, &run, rows, started: started)
                } catch let failure as DatabaseFailure { throw failed(q, &run, failure) }
            }
        } catch let failure as DatabaseFailure { throw failed(q, &run, failure) }
    }

    private func finish(_ q: DatabaseQuery, _ run: inout DatabaseRun, _ rows: DatabaseRows, started: Date)
        -> QueryResult
    {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let result = QueryResult(
            id: run.id, columns: rows.columns, rows: rows.rows, total: rows.total, changed: rows.changed, ms: ms)
        run.rows = rows.total
        run.changed = rows.changed
        run.ms = ms
        note(q.worktreeId, run, result: result)
        var sent = result
        sent.rows = Array(result.rows.prefix(max(0, q.limit ?? Int(sessions.settings[SettingKeys.databaseRows]))))
        return sent
    }

    private func failed(_ q: DatabaseQuery, _ run: inout DatabaseRun, _ failure: DatabaseFailure) -> RPCError {
        run.state = .failed
        run.error = failure.message
        note(q.worktreeId, run)
        return RPCError.invalidParams(failure.message)
    }

    /// The change tried and rolled back, then asked on the agent's row: whether the user allowed it.
    private func allowed(
        _ q: DatabaseQuery, _ c: DatabaseConnection, _ sql: String, _ run: inout DatabaseRun, session: String?
    ) async throws -> Bool {
        guard let session, let ls = sessions.existing(session) else {
            run.state = .refused
            run.error = "Nobody to ask: a change to \(c.database.name) needs the user's Allow on an agent's row."
            note(q.worktreeId, run)
            return false
        }
        var trial: DatabaseRows?
        do { trial = try await DatabaseEngines.trial(c, sql, off: offloads) } catch DatabaseFailure.failed(
            let why)
        {
            // It can't be tried in a transaction (CREATE INDEX CONCURRENTLY, MySQL's DDL): asked all the same.
            Log.session.info("db trial of \(c.database.name) didn't run: \(why)")
        }
        run.state = .asks
        run.changed = trial?.changed
        note(
            q.worktreeId, run,
            result: trial.map {
                QueryResult(id: run.id, columns: $0.columns, rows: $0.rows, total: $0.total, changed: $0.changed, ms: 0)
            })
        let question = Self.question(sql, database: c.database.name, changed: trial?.changed)
        ls.askForKelp(question)
        let answer = await sessions.permissions.waitForKelp(session, question: question, within: 600)
        ls.kelpAsked(question)
        guard answer == "allow" else {
            run.state = .denied
            run.error = answer == "deny" ? "The user denied it." : "Nobody answered: it's no longer asked."
            note(q.worktreeId, run)
            return false
        }
        return true
    }

    /// What the agent's row asks: "Allow changing 1204 rows in app_dev?". "allow" makes the banner, the Dock and the
    /// strip offer Allow / Deny (`Session.asksPermission`).
    static func question(_ sql: String, database: String, changed: Int?) -> String {
        if let changed, ["UPDATE", "DELETE", "INSERT", "MERGE", "REPLACE"].contains(SQLText.verb(sql)) {
            return "Allow changing \(changed) \(changed == 1 ? "row" : "rows") in \(database)?"
        }
        let line = SQLText.code(sql).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let short = line.count > 80 ? String(line.prefix(79)) + "…" : line
        return "Allow \(short) in \(database)?"
    }

    func schema(_ worktreeId: String, _ name: String, table: String?, agent: Bool) async throws -> DatabaseSchema {
        let c = try await offloads.run { [self] in try reach(connection(worktreeId, name, agent: agent), worktreeId) }
        do { return try await DatabaseEngines.schema(c, table: table, off: offloads) } catch let failure
            as DatabaseFailure
        {
            throw RPCError.invalidParams(failure.message)
        }
    }
}

extension DatabaseList: Handled {
    func handle(_ dbs: Databases) throws -> [DatabaseInfo] {
        let agent = dbs.agent(origin: Sessions.asker) != nil
        return try dbs.connections(worktreeId).map(\.database).filter { !agent || $0.agentAccess != .hidden }
    }
}

extension DatabaseSchemaRead: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> DatabaseSchema {
        try await dbs.schema(worktreeId, database, table: table, agent: dbs.agent(origin: Sessions.asker) != nil)
    }
}

extension DatabaseQuery: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> QueryResult { try await dbs.query(self, origin: Sessions.asker) }
}

extension DatabaseSave: Handled {
    func handle(_ dbs: Databases) throws -> DatabaseInfo {
        let secret = try password ?? container.map { try dbs.containerPassword($0, database.engine) } ?? nil
        return try dbs.save(worktreeId, database, password: secret, library: library ?? false)
    }
}

extension DatabaseRemove: Handled {
    func handle(_ dbs: Databases) throws -> Done {
        try dbs.remove(worktreeId, name, library: library ?? false)
        return Done()
    }
}

extension DatabaseCopy: AsyncHandled {
    func handle(_ dbs: Databases) async throws -> DatabaseInfo { try await dbs.copy(worktreeId, database) }
}

extension DatabaseActivity: Handled {
    func handle(_ dbs: Databases) throws -> DatabasesEvent { try dbs.activity(worktreeId) }
}

extension DatabaseResultRead: Handled {
    func handle(_ dbs: Databases) throws -> QueryResult? { dbs.result(worktreeId, id) }
}

extension Methods {
    static let databaseMethods: [any Handled.Type] = [
        DatabaseList.self, DatabaseSave.self, DatabaseRemove.self, DatabaseActivity.self, DatabaseResultRead.self,
        DatabaseUse.self
    ]
    /// What talks to a server: off the handlers' threads, over its own connection.
    static let databaseAsyncMethods: [any AsyncHandled.Type] = [
        DatabaseQuery.self, DatabaseSchemaRead.self, DatabaseCopy.self, DatabaseCheck.self, DatabaseContainers.self
    ]
}
