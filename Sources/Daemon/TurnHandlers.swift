import Core
import Foundation
import GitKit

// An agent's turns: their snapshots kept under refs/kelp/turns/, listed, undone and redone.

extension SessionTurnUndo: Handled {
    var actsOn: String? { id }   // an agent undoes only its own turns and its children's
    func handle(_ turns: Turns) throws -> Result {
        let (mark, dir) = try turns.place(session: id, turn: turn), remotes = turns.remotes
        let plan = try Git.changed(since: mark.tree, cwd: dir, remotes: remotes)
        guard apply == true else { return Plan(files: plan.files, state: plan.now) }
        let before = state ?? ""
        guard plan.now == before else {
            throw RPCError.invalidParams("The files changed since you looked; nothing was put back.")
        }
        // What it was before stays reachable for Redo (git gc keeps it), each undo's in the ref's log.
        try Git.run(
            ["update-ref", "--create-reflog", "-m", "undo turn " + turn, Turns.undoneRef(id), before], cwd: dir,
            remotes: remotes)
        do { try Git.restore(plan.files, from: mark.tree, now: before, cwd: dir, remotes: remotes) } catch {
            // Stopped part way (a file the Trash refused): the files it touched go back as they were, not half undone.
            let back: Void? = Log.session.attempt("putting a stopped undo back") {
                let changed = try Git.changed(since: before, cwd: dir, remotes: remotes)
                try Git.restore(
                    changed.files.filter(plan.files.contains), from: before, now: changed.now, cwd: dir,
                    remotes: remotes)
            }
            let why = (error as? GitError)?.stderr ?? "\(error)"
            let now = back != nil ? "The files are as they were." : "Some went back; Redo puts them as they were."
            throw RPCError.invalidParams("The turn wasn't undone (\(why)). " + now)
        }
        return Plan(files: plan.files, state: try Git.snapshotTree(dir, remotes: remotes))
    }
}

extension SessionTurnRedo: Handled {
    var actsOn: String? { id }
    func handle(_ turns: Turns) throws -> Done {
        let (_, dir) = try turns.place(session: id, turn: turn), remotes = turns.remotes, ref = Turns.undoneRef(id)
        let before = try Git.run(["rev-parse", "--verify", "-q", ref], cwd: dir, ok: [0, 1], remotes: remotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty else { throw RPCError.invalidParams("There's no undo to take back here.") }
        let plan = try Git.changed(since: before, cwd: dir, remotes: remotes)
        try Git.restore(plan.files, from: before, now: state, cwd: dir, remotes: remotes)
        try Git.run(["update-ref", "-d", ref], cwd: dir, remotes: remotes)
        return Done()
    }
}

/// The turns agents take: the snapshot each began with, kept under refs/kelp/turns/ for its diff, and undoing or redoing
/// one (`session.turnUndo`).
struct Turns: Sendable {
    let live: SessionTable, store: Store, remotes: Remotes

    /// The folder before the session's last undone turn.
    static func undoneRef(_ session: String) -> String { "refs/kelp/undone/" + session }

    /// The turn and the checkout's top, when a turn may be undone or redone there: the agent rests, no commits since the
    /// turn began, no other agent in the checkout, and its snapshot still there.
    func place(session id: String, turn: String) throws -> (SessionTurns.Mark, String) {
        guard try store.session(id) != nil else { throw RPCError.invalidParams("No such agent.") }
        let status = live[id]?.snapshot.status   // nil: paused, so not in a turn
        guard let mark = try store.turns(session: id).first(where: { $0.id == turn }) else {
            throw RPCError.invalidParams("No such turn.")
        }
        let remotes = remotes, dir = try Git.root(of: mark.folder, remotes: remotes)   // paths count from the top, whatever folder it was in
        guard status != .working, status != .waiting else {
            throw RPCError.invalidParams("The agent is still in its turn: stop it first.")
        }
        let head = try Git.run(["rev-parse", "--verify", "-q", "HEAD"], cwd: dir, ok: [0, 1], remotes: remotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (head.isEmpty ? nil : head) == mark.head else {
            throw RPCError.invalidParams("Commits were made since that turn began; undoing it now would mix them up.")
        }
        let others = live.all.filter { other in   // anywhere in the checkout, by any path to it
            let snapshot = other.snapshot
            return snapshot.id != id && snapshot.status != .exited && snapshot.isAgent
                && IDE.inside(other.turnDir ?? snapshot.cwd, dir)
        }
        guard others.isEmpty else {
            throw RPCError.invalidParams("Another agent works in this folder: its changes would go too.")
        }
        guard
            try !Git.run(["rev-parse", "--verify", "-q", mark.tree + "^{tree}"], cwd: dir, ok: [0, 1], remotes: remotes)
                .isEmpty
        else {
            throw RPCError.invalidParams("That turn's snapshot is gone: git cleaned it up.")
        }
        return (mark, dir)
    }

    /// A turn that began, kept with its snapshot under refs/kelp/turns/ so `git gc` doesn't take it while the turn is listed;
    /// the turns that drop off the list let theirs go.
    /// Its session deleted while the snapshot was taken: no turn, and no ref. Deleted between the two, the delete's own
    /// `dropRefs` may have run before the ref was made: it's dropped here.
    func keep(_ mark: SessionTurns.Mark) {
        Log.store.attempt("keeping a turn") {
            guard let dropped = try store.addTurn(mark), remotes.of(mark.folder) == nil else { return }   // no snapshots on a host
            let ref = "refs/kelp/turns/" + mark.id
            try Git.run(["update-ref", ref, mark.tree], cwd: mark.folder, remotes: remotes)
            delete(
                dropped.map { ("refs/kelp/turns/" + $0.id, $0.folder) }
                    + (try store.session(mark.session) == nil ? [(ref, mark.folder)] : []))
        }
    }

    /// A session going: its turns' snapshots and its last undone state needn't be kept any more. `repo`: where to drop
    /// them when their folder, a removed worktree, is gone; the refs are in the project's repository, which it shared.
    func dropRefs(of session: String, in repo: String? = nil) {
        Log.store.attempt("dropping \(session)'s turn refs") {
            dropRefs(try store.turns(session: session), of: session, in: repo)
        }
    }
    func dropRefs(_ marks: [SessionTurns.Mark], of session: String, in repo: String? = nil) {
        delete(
            marks.map { ("refs/kelp/turns/" + $0.id, repo ?? $0.folder) }
                + marks.prefix(1).map { (Self.undoneRef(session), repo ?? $0.folder) })
    }

    /// Deletes each ref in its folder's repository, one git run per repository; one already gone, or a folder that is,
    /// stops none of the others.
    private func delete(_ refs: [(ref: String, folder: String)]) {
        for (folder, group) in Dictionary(grouping: refs, by: \.folder)
        where remotes.of(folder) == nil && FileManager.default.fileExists(atPath: folder) {
            Log.store.attempt("dropping turn refs in \(folder)") {
                _ = try Git.run(
                    ["update-ref", "--stdin"], cwd: folder, stdin: group.map { "delete \($0.ref)\n" }.joined(),
                    remotes: remotes)
            }
        }
    }
}

extension SessionTurns: Handled {
    func handle(_ turns: Turns) throws -> Result { try turns.store.turns(session: id) }
}

extension SessionTurn: Handled {
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
