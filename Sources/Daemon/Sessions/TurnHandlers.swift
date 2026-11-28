import Core
import Foundation
import GitKit
import os

// An agent's turns: their snapshots kept under refs/kelp/turns/, listed, undone and redone.

extension SessionTurnUndo: AsyncHandled {
    var fence: Fence { Fence(actsOn: id) }   // an agent undoes only its own turns and its children's
    /// The databases the turn changed go back first, so a failure there leaves everything as it was, and they are put
    /// back as the undo found them when the files can't go.
    func handle(_ turns: Turns) async throws -> Result {
        let databases = turns.databases.databases
        let (mark, dir, plan, later, agent) = try await turns.offloads.run { [self] in
            let (mark, dir) = try turns.place(session: id, turn: turn)
            let session = try turns.store.session(id)
            let agent = session.flatMap { session in
                Log.session.attempt("reading an agent's name") {
                    try turns.setup.manifest(session.agent, command: nil, fallbackArgv: session.argv).name
                }
            }
            let later = try turns.store.turns(session: id).prefix { $0.id != turn }.map(\.id)
            return (mark, dir, try Git.changed(since: mark.tree, cwd: dir, remotes: turns.remotes), later, agent)
        }
        let found = databases?.turnDatabases(turn, later: later, files: plan.files, top: dir) ?? []
        // Only those the sheet listed go back: one changed since it was shown isn't put back unasked
        let listed = self.databases   // the request's names; `databases` here is the project's
        let dbs = apply == true ? found.filter { listed?.contains(Turns.sheetName($0)) ?? true } : found
        guard apply == true else {
            return Plan(
                files: plan.files, state: plan.now, databases: dbs.isEmpty ? nil : Turns.sheet(dbs, agent: agent))
        }
        let before = state ?? ""
        guard plan.now == before else {
            throw RPCError.invalidParams("The files changed since you looked; nothing was put back.")
        }
        try await databases?.undoTurn(dbs, undone: Turns.undoneKey(id))
        do {
            return Plan(
                files: plan.files,
                state: try await turns.offloads.run { [self] in try undoFiles(turns, mark, dir, plan.files, before) }
            )
        } catch {
            let stuck = await databases?.redoTurn(Turns.undoneKey(id)) ?? []
            guard let stayed = Databases.stayed(stuck), var said = error as? RPCError else { throw error }
            said.message += " " + stayed
            throw said
        }
    }

    /// Puts the files back as `mark` found them, while the folder is still at `before`. Returns its state after.
    private func undoFiles(
        _ turns: Turns, _ mark: SessionTurns.Mark, _ dir: String, _ files: [String], _ before: String
    )
        throws -> String
    {
        let remotes = turns.remotes
        // The state before the undo stays reachable for Redo (git gc keeps it), since each undo is in the ref's log.
        try Git.setRef(Turns.undoneRef(id), to: before, reflog: "undo turn " + turn, cwd: dir, remotes: remotes)
        // Also keep what was staged before the undo, so Redo takes the undo back whole. When nothing could be kept
        // (conflicts), the older staged ref is dropped.
        let staged = try Git.indexTree(dir, remotes: remotes)
        try Git.setRef(Turns.undoneStagedRef(id), to: staged, cwd: dir, remotes: remotes)
        let index = try turns.kept(Turns.stagedRef(mark.id), in: dir)
        do {
            try Git.restore(files, from: mark.tree, now: before, index: index, cwd: dir, remotes: remotes)
        } catch {
            // If it stopped part way (a file the Trash refused), the files it touched go back as they were, not half
            // undone.
            let back: Void? = Log.session.attempt("putting a stopped undo back") {
                let changed = try Git.changed(since: before, cwd: dir, remotes: remotes)
                try Git.restore(
                    changed.files.filter(files.contains), from: before, now: changed.now, index: staged,
                    cwd: dir, remotes: remotes)
            }
            let why = (error as? GitError)?.message ?? "\(error)"
            let now = back != nil ? "The files are as they were." : "Some went back; Redo puts them as they were."
            throw RPCError.invalidParams("The turn wasn't undone (\(why)). " + now)
        }
        return try Git.snapshotTree(dir, remotes: remotes)
    }
}

extension SessionTurnRedo: AsyncHandled {
    var fence: Fence { Fence(actsOn: id) }
    func handle(_ turns: Turns) async throws -> Done {
        try await turns.offloads.run { [self] in
            let (_, dir) = try turns.place(session: id, turn: turn), remotes = turns.remotes, ref = Turns.undoneRef(id)
            guard let before = try turns.kept(ref, in: dir) else {
                throw RPCError.invalidParams("There's no undo to take back here.")
            }
            let plan = try Git.changed(since: before, cwd: dir, remotes: remotes), staged = Turns.undoneStagedRef(id)
            try Git.restore(
                plan.files, from: before, now: state, index: try turns.kept(staged, in: dir), cwd: dir,
                remotes: remotes)
            try Git.setRef(ref, to: nil, cwd: dir, remotes: remotes)
            try Git.setRef(staged, to: nil, cwd: dir, remotes: remotes)
        }
        let failed = await turns.databases.databases?.redoTurn(Turns.undoneKey(id)) ?? []
        guard failed.isEmpty else {
            throw RPCError.invalidParams(
                "The files came back; \(failed.joined(separator: ", ")) didn't, and stays as the undo left it.")
        }
        return Done()
    }
}

/// The turns agents take: the snapshot each began with, kept under refs/kelp/turns/ for its diff, and undoing or redoing
/// one (`session.turnUndo`).
struct Turns: Sendable {
    let live: SessionTable, store: Store, remotes: Remotes
    let databases: TurnDatabases   // the databases as each turn found them, which its undo puts back too
    let offloads: Slots, setup: SessionSetup   // the undo's git runs off the pool; the sheet names the agent
    /// Each trail's status changes as `session.history` last read them, by path, with the file's size and date then.
    /// The Overview asks again at every status change of any agent, and most trails are of agents at rest.
    let trailsRead = OSAllocatedUnfairLock(initialState: [String: (stamp: [Int], changes: [SessionHistory.Change])]())

    init(live: SessionTable, store: Store, remotes: Remotes, root: URL, offloads: Slots, setup: SessionSetup) {
        (self.live, self.store, self.remotes, self.offloads, self.setup) = (live, store, remotes, offloads, setup)
        databases = TurnDatabases(root: root)
    }

    /// Where the databases are kept as the session's last undo found them, for Redo.
    static func undoneKey(_ session: String) -> String { "undone-" + session }

    /// The databases as the undo's sheet lists them: by file name ("shop.sqlite") or name, with what `agent` did.
    static func sheet(_ dbs: [TurnDatabase], agent: String?) -> [SessionTurnUndo.Database] {
        dbs.map { one in
            SessionTurnUndo.Database(
                name: sheetName(one),
                detail: Databases.said(agent: agent ?? "The agent", one.kept.runs, one.kept.engine),
                cannot: one.kept.cannot)
        }
    }

    static func sheetName(_ one: TurnDatabase) -> String {
        one.kept.path.map { ($0 as NSString).lastPathComponent } ?? one.kept.name
    }

    /// The ref that keeps the folder as it was before the session's last undone turn.
    static func undoneRef(_ session: String) -> String { "refs/kelp/undone/" + session }
    /// The refs that keep what was staged before that undo, and what was staged when a turn began (`Git.turnSnapshot`).
    /// Each is kept as long as the snapshot it was taken with.
    static func undoneStagedRef(_ session: String) -> String { "refs/kelp/undone-staged/" + session }
    static func stagedRef(_ turn: String) -> String { "refs/kelp/staged/" + turn }
    private static func refs(_ mark: SessionTurns.Mark) -> [String] {
        ["refs/kelp/turns/" + mark.id, stagedRef(mark.id)]
    }

    /// The tree one of these refs keeps, or nil when there is none (nothing was undone, or nothing staged could be
    /// kept).
    func kept(_ ref: String, in dir: String) throws -> String? {
        try Git.resolve(ref, cwd: dir, remotes: remotes)
    }

    /// Returns the turn and the checkout's top folder when the turn may be undone or redone there: the agent rests, no
    /// commits were made since the turn began, no other agent is in the checkout, and the turn's snapshot is still
    /// there.
    func place(session id: String, turn: String) throws -> (SessionTurns.Mark, String) {
        guard try store.session(id) != nil else { throw RPCError.noSession(id) }
        let status = live[id]?.snapshot.status   // nil: paused, so not in a turn
        guard let mark = try store.turns(session: id).first(where: { $0.id == turn }) else {
            throw RPCError.invalidParams("No such turn.")
        }
        let remotes = remotes, dir = try Git.root(of: mark.folder, remotes: remotes)   // paths count from the top, whatever folder it was in
        guard status != .working, status != .waiting else {
            throw RPCError.invalidParams("The agent is still in its turn: stop it first.")
        }
        guard try Git.head(dir, remotes: remotes) == mark.head else {
            throw RPCError.invalidParams("Commits were made since that turn began; undoing it now would mix them up.")
        }
        let others = live.all.filter { other in   // anywhere in the checkout, by any path to it
            let snapshot = other.snapshot
            return snapshot.id != id && snapshot.status != .exited && snapshot.isAgent
                && Paths.inside(other.turnDir ?? snapshot.cwd, dir)
        }
        guard others.isEmpty else {
            throw RPCError.invalidParams("Another agent works in this folder: its changes would go too.")
        }
        guard try Git.resolve(mark.tree + "^{tree}", cwd: dir, remotes: remotes) != nil else {
            throw RPCError.invalidParams("That turn's snapshot is gone: git cleaned it up.")
        }
        return (mark, dir)
    }

    /// Keeps a turn that began, with its snapshot under refs/kelp/turns/ so `git gc` doesn't take it while the turn is
    /// listed. The turns that drop off the list let theirs go.
    /// If the session was deleted while the snapshot was taken, there is no turn and no ref. If it was deleted between
    /// the two, the delete's own `dropRefs` may have run before the ref was made, so the ref is dropped here.
    /// `staged` is what the user had staged (`Git.turnSnapshot`), for the turn's undo to leave staged. This turn's refs
    /// and those of the dropped turns in its repository are written in one git run.
    func keep(_ mark: SessionTurns.Mark, staged: String?) {
        Log.store.attempt("keeping a turn") {
            if let worktreeId = try store.session(mark.session)?.worktreeId {
                databases.databases?.keepFiles(mark.id, worktreeId: worktreeId)
            }
            guard let dropped = try store.addTurn(mark) else { return databases.drop([mark.id]) }
            databases.drop(dropped.map(\.id))
            let here = dropped.filter { $0.folder == mark.folder },
                elsewhere = dropped.filter { $0.folder != mark.folder }
            try Git.deleteRefs(
                here.flatMap(Self.refs),
                setting: [("refs/kelp/turns/" + mark.id, mark.tree)]
                    + (staged.map { [(Self.stagedRef(mark.id), $0)] } ?? []),
                cwd: mark.folder, remotes: remotes)
            delete(
                (elsewhere + (try store.session(mark.session) == nil ? [mark] : [])).flatMap { old in
                    Self.refs(old).map { ($0, old.folder) }
                })
        }
    }

    /// Drops the refs of a session that is going: its turns' snapshots and its last undone state needn't be kept any
    /// more. `repo` is where to drop them when their folder, a removed worktree, is gone, because the refs are in the
    /// project's repository, which the worktree shared.
    func dropRefs(of session: String, in repo: String? = nil) {
        Log.store.attempt("dropping \(session)'s turn refs") {
            dropRefs(try store.turns(session: session), of: session, in: repo)
        }
    }
    func dropRefs(_ marks: [SessionTurns.Mark], of session: String, in repo: String? = nil) {
        databases.drop(marks.map(\.id) + [Self.undoneKey(session)])
        delete(
            marks.flatMap { mark in Self.refs(mark).map { ($0, repo ?? mark.folder) } }
                + marks.prefix(1).flatMap { mark in
                    [Self.undoneRef(session), Self.undoneStagedRef(session)].map { ($0, repo ?? mark.folder) }
                })
    }

    /// Deletes each ref in its folder's repository, one git run per repository. A ref already gone, or a folder that is
    /// gone, stops none of the others.
    private func delete(_ refs: [(ref: String, folder: String)]) {
        for (folder, group) in Dictionary(grouping: refs, by: \.folder)
        where FileManager.default.fileExists(atPath: folder) {
            Log.store.attempt("dropping turn refs in \(folder)") {
                try Git.deleteRefs(group.map(\.ref), cwd: folder, remotes: remotes)
            }
        }
    }
}

extension SessionTurns: Handled {
    static let agents = AgentAccess.reads
    func handle(_ turns: Turns) throws -> Result { try turns.store.turns(session: id) }
}

extension SessionTurn: Handled {
    static let agents = AgentAccess.acts
    static var quick: Bool { true }
    func handle(_ turns: Turns) throws -> Info? {
        guard let ls = turns.live[id] else { return nil }
        let turn = ls.lastTurn.map { last in
            Turn(
                files: last.files.map { .init(path: $0.path, added: $0.added, removed: $0.removed) },
                seconds: last.seconds)
        }
        return Info(turn: turn, hasBase: ls.turnBase != nil)
    }
}

extension Methods {
    static let turnMethods: [any Answered.Type] = [
        SessionTurnUndo.self, SessionTurnRedo.self, SessionTurns.self, SessionTurn.self
    ]
}
