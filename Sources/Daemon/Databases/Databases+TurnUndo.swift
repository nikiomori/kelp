import Core
import Foundation

// Undoing an agent's turn puts back the databases it changed (`session.turnUndo`), and Redo takes that back.

extension Databases {
    /// The databases that undoing `turn` puts back: each as kept when the turn began, or, for a Postgres copy the turn
    /// didn't change, when a later turn first did (`later`, the newer turns, newest first). Only those changed since
    /// are listed. A file in git (in `files` from `top`) goes back with the files instead.
    func turnDatabases(_ turn: String, later: [String], files: [String], top: String) -> [TurnDatabase] {
        var found: [TurnDatabase] = []
        for key in [turn] + later.reversed() {
            for (index, kept) in turnKeeps.kept(key).enumerated()
            where !found.contains(where: { $0.kept.name == kept.name }) {
                guard key == turn || kept.template != nil else { continue }   // files are kept as every turn begins
                var one = TurnDatabase(key: key, index: index, kept: kept)
                if key != turn { one.kept.runs = [] }   // what a later turn did isn't this one's
                found.append(one)
            }
        }
        return found.filter { one in
            guard let path = one.kept.path else { return true }   // a Postgres copy is kept only as it's changed
            let inGit =
                Paths.inside(path, top)
                && files.contains(String(Paths.realNearest(path).dropFirst(Paths.realNearest(top).count + 1)))
            return !inGit && (!one.kept.runs.isEmpty || TurnDatabases.stamp(path, one.kept.engine) != one.kept.stamp)
        }
    }

    /// Puts the databases back as the turn kept them, keeping each as it is now under `undone` first (for Redo). When
    /// one can't go back, those already put back are put as they were, and it throws.
    func undoTurn(_ all: [TurnDatabase], undone: String) async throws {
        // An older undo's state, which Redo can no longer reach, goes first: its Postgres copy has this one's name
        let older = turnKeeps.kept(undone)
        FileManager.default.removeIfAny(turnKeeps.folder(undone))
        await dropTemplates(older)
        for one in all where one.kept.cannot == nil {
            do {
                try await undo(one, keeping: turnKeeps.kept(undone).count, in: undone)
            } catch {
                let stuck = await redoTurn(undone)
                let why = (error as? DatabaseFailure)?.message ?? "\(error)"
                throw RPCError.invalidParams(
                    "\(one.kept.name) couldn't go back (\(why)); " + (Self.stayed(stuck) ?? "nothing was put back."))
            }
        }
    }

    /// Puts one database back, after keeping it as it is now at `index` in `undone` and listing it there. A file is
    /// listed before it goes back, so a put-back that fails part way is put as it was too (`redoTurn`).
    private func undo(_ one: TurnDatabase, keeping index: Int, in undone: String) async throws {
        var now = KeptDatabase(worktreeId: one.kept.worktreeId, name: one.kept.name, engine: one.kept.engine)
        if let path = one.kept.path {
            let (engine, here, from) = (
                one.kept.engine, turnKeeps.file(undone, index), turnKeeps.file(one.key, one.index)
            )
            try await offloads.run { try TurnDatabases.clone(path, engine, to: here) }
            now.path = path
            try turnKeeps.change(undone) { $0.append(now) }
            try await offloads.run { try TurnDatabases.putBack(path, engine, from: from) }
            return
        }
        let target = try await offloads.run { [self] in
            try connection(one.kept.worktreeId, one.kept.name, agent: false)
        }
        guard let live = target.database.database, let template = one.kept.template else {
            throw DatabaseFailure.failed("it isn't a Postgres database any more")
        }
        let aside = Self.templateName(undone, one.kept.name),
            steps = Self.undoSQL(live, template: template, aside: aside)
        try await maintenance(target, [steps.rename])
        do { try await maintenance(target, [steps.create]) } catch {
            do { try await maintenance(target, [steps.back]) } catch let back {
                Log.store.error("naming \(aside) \(live) again after its undo failed: \(back)")
            }
            throw error
        }
        now.template = aside
        try turnKeeps.change(undone) { $0.append(now) }
    }

    /// The statements that put a Postgres copy back from `template`: the copy is renamed `aside` (where Redo finds
    /// it), and made again from the template. If that fails, `back` names it as it was. Renaming, like copying, needs
    /// nothing connected to it.
    static func undoSQL(_ live: String, template: String, aside: String) -> (
        rename: String, create: String, back: String
    ) {
        (renameSQL(live, to: aside), copySQL(live, from: template), renameSQL(aside, to: live))
    }

    /// Takes back the last undo: each database kept in `undone` goes back as the undo found it. Returns the names of
    /// those that couldn't.
    @discardableResult
    func redoTurn(_ undone: String) async -> [String] {
        var failed: [String] = []
        for (index, kept) in turnKeeps.kept(undone).enumerated() {
            do {
                if let path = kept.path {
                    let from = turnKeeps.file(undone, index)
                    try await offloads.run { try TurnDatabases.putBack(path, kept.engine, from: from) }
                } else if let aside = kept.template {
                    let target = try await offloads.run { [self] in
                        try connection(kept.worktreeId, kept.name, agent: false)
                    }
                    guard let live = target.database.database else { throw DatabaseFailure.failed("no database") }
                    let temp = Self.templateName("redo-" + undone, kept.name)
                    do {
                        try await Self.swap(aside, for: live, temp: temp) { try await maintenance(target, [$0]) }
                    } catch let stranded as Stranded {
                        // Neither holds the copy's name now: neither is dropped later as the undo's spare
                        Log.store.attempt("keeping \(aside) from being dropped") {
                            try turnKeeps.change(undone) { all in
                                (all[index].template, all[index].cannot) = (nil, stranded.why)
                            }
                        }
                        throw stranded
                    }
                }
            } catch {
                Log.store.error("putting \(kept.name) back as the undo found it: \(error)")
                failed.append(kept.name)
            }
        }
        // What couldn't go back stays kept until the next undo drops it
        if failed.isEmpty { FileManager.default.removeIfAny(turnKeeps.folder(undone)) }
        return failed
    }

    /// What a failed undo says of the databases `redoTurn` couldn't take back (`stuck`): nil when there are none.
    static func stayed(_ stuck: [String]) -> String? {
        stuck.isEmpty ? nil : stuck.joined(separator: ", ") + " stayed as the undo left them."
    }

    /// A swap that couldn't put the copy's name back (`swap`).
    struct Stranded: Error { var why: String }

    /// Puts the Postgres database `aside` in the place of `live`, `run`ning each statement. `live` is named `temp`
    /// first and dropped once `aside` has its name, so a step that fails names it back, leaving both as they were.
    /// When even that fails, it throws `Stranded`.
    static func swap(_ aside: String, for live: String, temp: String, _ run: (String) async throws -> Void)
        async throws
    {
        try await run(renameSQL(live, to: temp))
        do { try await run(renameSQL(aside, to: live)) } catch {
            do { try await run(renameSQL(temp, to: live)) } catch {
                throw Stranded(why: "\(live) is named \(temp) on its server, and the undo's state \(aside).")
            }
            throw error
        }
        do { try await run(dropSQL(temp)) } catch {
            Log.store.error("dropping \(temp), \(live) as it was before a redo: \(error)")
        }
    }

    // MARK: What the sheet says

    /// What the agent did to a database in the turn, from its runs: "Claude Code changed it 3 times in this turn: 214
    /// rows of orders, 1 new column." Rows are counted by table where a change names one table, and what can't be
    /// told is left out. nil without runs.
    static func said(agent: String, _ runs: [DatabaseRun], _ engine: DatabaseInfo.Engine) -> String? {
        guard !runs.isEmpty else { return nil }
        var rows: [(table: String, count: Int)] = [], columns = 0
        for run in runs {
            let statements =
                Log.store.attempt("reading a turn's change") { try SQLText.several(run.sql, engine) } ?? [run.sql]
            columns += statements.reduce(0) { $0 + addedColumns($1) }
            let tables = Set(statements.compactMap { table($0) })
            guard let table = tables.first, tables.count == 1, let changed = run.changed, changed > 0 else { continue }
            if let at = rows.firstIndex(where: { $0.table == table }) {
                rows[at].count += changed
            } else {
                rows.append((table, changed))
            }
        }
        let parts =
            rows.map { "\($0.count) \($0.count == 1 ? "row" : "rows") of \($0.table)" }
            + (columns > 0 ? ["\(columns) new \(columns == 1 ? "column" : "columns")"] : [])
        let times = runs.count == 1 ? "once" : "\(runs.count) times"
        return "\(agent) changed it \(times) in this turn"
            + (parts.isEmpty ? "." : ": " + parts.joined(separator: ", ") + ".")
    }

    /// How many columns an ALTER TABLE adds: each ADD [COLUMN] that isn't a constraint or an index.
    static func addedColumns(_ sql: String) -> Int {
        let code = SQLText.code(sql)
        guard SQLText.verb(code) == "ALTER",
            code.range(of: #"^ALTER\s+TABLE\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return 0 }
        let add =
            #/(?i)\bADD\s+(?!(?:CONSTRAINT|INDEX|KEY|PRIMARY|UNIQUE|FOREIGN|CHECK|FULLTEXT|SPATIAL|PARTITION)\b)/#
        return code.matches(of: add).count
    }
}
