import Core
import Foundation

// An agent's turn keeps the databases it may change, so that undoing the turn puts them back with the files
// (TurnDatabases.swift has where they are kept).

/// One database that undoing a turn puts back: what was kept of it, in the turn `key`'s folder at `index`.
struct TurnDatabase: Sendable, Equatable {
    var key: String, index: Int, kept: KeptDatabase
}

extension Databases {
    /// Keeps the workspace's SQLite and DuckDB files on this Mac as the turn `key` begins.
    /// Limit: the clone is taken after the turn's snapshot of the files, so a change in the moment between is kept as
    /// part of what the turn found.
    func keepFiles(_ key: String, worktreeId: String) {
        // A remote project's files are on its host, where no SQLite file is looked for: none is found here
        let files = (Log.store.attempt("listing the turn's databases") { try connections(worktreeId) } ?? [])
            .map(\.database).filter { $0.engine.isFile && FileManager.default.fileExists(atPath: $0.path ?? "") }
        guard !files.isEmpty else { return }
        Log.store.attempt("keeping the turn's databases") {
            try turnKeeps.change(key) { all in
                for db in files {
                    guard let path = db.path else { continue }
                    let stamp = TurnDatabases.stamp(path, db.engine), at = turnKeeps.file(key, all.count)
                    let cloned: Void? = Log.store.attempt("cloning \(db.name) for the turn") {
                        try TurnDatabases.clone(path, db.engine, to: at)
                    }
                    guard cloned != nil else { continue }
                    all.append(
                        KeptDatabase(worktreeId: worktreeId, name: db.name, engine: db.engine, path: path, stamp: stamp)
                    )
                }
            }
        }
    }

    /// The turn the agent `session` is in now, or nil between turns.
    func currentTurn(_ session: String) -> String? {
        guard let started = live[session]?.turnStarted,
            let mark = (Log.store.attempt("reading the turns") { try store.turns(session: session) })?.first,
            mark.at >= started
        else { return nil }
        return mark.id
    }

    /// Whether Kelp keeps a database by making a copy of it in Postgres: a branch's own copy on this Mac.
    static func keepsAsTemplate(_ db: DatabaseInfo) -> Bool {
        db.engine == .postgres && db.copy != nil && db.ssh == nil && db.host.map(DatabaseInfo.isLocal) == true
            && db.database != nil
    }

    /// Before an agent's change: a branch's own Postgres copy is kept as the turn found it, at the turn's first change
    /// of it. When Postgres can't copy it (something is connected to it), that is kept too, for the undo to say.
    func turnChanging(_ session: String?, _ target: DatabaseConnection, _ worktreeId: String) async {
        let db = target.database
        guard let session, Self.keepsAsTemplate(db), let key = currentTurn(session), let live = db.database,
            !turnKeeps.kept(key).contains(where: { $0.name == db.name && $0.template != nil })
        else { return }
        var kept = KeptDatabase(worktreeId: worktreeId, name: db.name, engine: .postgres)
        let template = Self.templateName(key, db.name)
        do {
            try await maintenance(target, [Self.copySQL(template, from: live)])
            kept.template = template
        } catch {
            let why = (error as? DatabaseFailure)?.message ?? "\(error)"
            kept.cannot =
                "Postgres couldn't copy it before the turn's first change (\(why))."
                + (why.contains("other users") ? " Nothing may be connected to it then, such as a dev server." : "")
        }
        Log.store.attempt("keeping \(db.name) for the turn") {
            try turnKeeps.change(key) { all in
                // Two changes at once both try; a copy made wins over the other's failure
                if let at = all.firstIndex(where: { $0.name == kept.name }) {
                    if kept.template != nil { all[at] = kept }
                } else {
                    all.append(kept)
                }
            }
        }
    }

    /// After an agent's change: it is kept with the turn, for the undo to say what the turn did.
    func turnChanged(_ run: DatabaseRun) {
        guard let session = run.session, run.state == .done, let key = currentTurn(session) else { return }
        Log.store.attempt("keeping a change with its turn") {
            try turnKeeps.change(key) { all in
                if let at = all.firstIndex(where: { $0.name == run.database }) { all[at].runs.append(run) }
            }
        }
    }

    /// Runs `statements` from the server's own `postgres` database, since nobody may be connected to a database that
    /// is copied, renamed or dropped.
    func maintenance(_ target: DatabaseConnection, _ statements: [String]) async throws {
        var near = try await offloads.run { [self] in try reach(target, target.database.copy?.worktreeId ?? "") }
        near.database.database = "postgres"
        for sql in statements { _ = try await DatabaseEngines.write(near, sql, off: offloads) }
    }

    /// Drops the Postgres databases kept for turns that are no longer listed. A failure goes to the log.
    func dropTemplates(_ kept: [KeptDatabase]) async {
        for one in kept {
            guard let template = one.template else { continue }
            do {
                let target = try await offloads.run { [self] in try connection(one.worktreeId, one.name, agent: false) }
                try await maintenance(target, [Self.dropSQL(template)])
            } catch { Log.store.error("dropping \(template), kept for a turn: \(error)") }
        }
    }

    // MARK: The SQL

    /// The Postgres database a turn (or an undo) keeps a copy in, such as kelp_6f1c2a4e_9d1b_4c_shop_fix.
    static func templateName(_ key: String, _ name: String) -> String {
        "kelp_" + slug(key).prefix(19) + "_" + slug(name)
    }
    static func copySQL(_ new: String, from database: String) -> String {
        let pg = DatabaseInfo.Engine.postgres
        return "CREATE DATABASE \(pg.quoted(new)) TEMPLATE \(pg.quoted(database))"
    }
    static func renameSQL(_ database: String, to new: String) -> String {
        let pg = DatabaseInfo.Engine.postgres
        return "ALTER DATABASE \(pg.quoted(database)) RENAME TO \(pg.quoted(new))"
    }
    static func dropSQL(_ database: String) -> String {
        "DROP DATABASE IF EXISTS \(DatabaseInfo.Engine.postgres.quoted(database))"
    }
}
