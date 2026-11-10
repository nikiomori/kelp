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
        // And what was staged before it, so Redo is the undo taken back whole; none (conflicts) drops an older one's.
        let staged = try Git.indexTree(dir, remotes: remotes)
        try Git.run(
            ["update-ref"] + (staged.map { [Turns.undoneStagedRef(id), $0] } ?? ["-d", Turns.undoneStagedRef(id)]),
            cwd: dir, remotes: remotes)
        let index = try turns.kept(Turns.stagedRef(mark.id), in: dir)
        do {
            try Git.restore(plan.files, from: mark.tree, now: before, index: index, cwd: dir, remotes: remotes)
        } catch {
            // Stopped part way (a file the Trash refused): the files it touched go back as they were, not half undone.
            let back: Void? = Log.session.attempt("putting a stopped undo back") {
                let changed = try Git.changed(since: before, cwd: dir, remotes: remotes)
                try Git.restore(
                    changed.files.filter(plan.files.contains), from: before, now: changed.now, index: staged,
                    cwd: dir, remotes: remotes)
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
        guard let before = try turns.kept(ref, in: dir) else {
            throw RPCError.invalidParams("There's no undo to take back here.")
        }
        let plan = try Git.changed(since: before, cwd: dir, remotes: remotes), staged = Turns.undoneStagedRef(id)
        try Git.restore(
            plan.files, from: before, now: state, index: try turns.kept(staged, in: dir), cwd: dir, remotes: remotes)
        try Git.run(["update-ref", "-d", ref], cwd: dir, remotes: remotes)
        try Git.run(["update-ref", "-d", staged], cwd: dir, remotes: remotes)
        return Done()
    }
}

/// The turns agents take: the snapshot each began with, kept under refs/kelp/turns/ for its diff, and undoing or redoing
/// one (`session.turnUndo`).
struct Turns: Sendable {
    let live: SessionTable, store: Store, remotes: Remotes

    /// The folder before the session's last undone turn.
    static func undoneRef(_ session: String) -> String { "refs/kelp/undone/" + session }
    /// What was staged before it, and what was when a turn began (`Git.indexTree`), each kept as long as the snapshot
    /// it was taken with.
    static func undoneStagedRef(_ session: String) -> String { "refs/kelp/undone-staged/" + session }
    static func stagedRef(_ turn: String) -> String { "refs/kelp/staged/" + turn }
    private static func refs(_ mark: SessionTurns.Mark) -> [String] {
        ["refs/kelp/turns/" + mark.id, stagedRef(mark.id)]
    }

    /// The tree a ref of these keeps, nil when there is none: nothing was undone, or nothing staged could be kept.
    func kept(_ ref: String, in dir: String) throws -> String? {
        let tree = try Git.line(["rev-parse", "--verify", "-q", ref], cwd: dir, ok: [0, 1], remotes: remotes)
        return tree.isEmpty ? nil : tree
    }

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
            // What the user had staged, for the turn's undo to leave staged. Limit: read here, a moment after the
            // snapshot (one git run): what an agent stages in that moment counts as the user's.
            let staged =
                Log.store.attempt("reading what's staged") {
                    try Git.indexTree(mark.folder, remotes: remotes)
                } ?? nil
            guard let dropped = try store.addTurn(mark), remotes.of(mark.folder) == nil else { return }   // no snapshots on a host
            try Git.run(["update-ref", "refs/kelp/turns/" + mark.id, mark.tree], cwd: mark.folder, remotes: remotes)
            if let staged {
                try Git.run(["update-ref", Self.stagedRef(mark.id), staged], cwd: mark.folder, remotes: remotes)
            }
            delete(
                (dropped + (try store.session(mark.session) == nil ? [mark] : [])).flatMap { old in
                    Self.refs(old).map { ($0, old.folder) }
                })
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
            marks.flatMap { mark in Self.refs(mark).map { ($0, repo ?? mark.folder) } }
                + marks.prefix(1).flatMap { mark in
                    [Self.undoneRef(session), Self.undoneStagedRef(session)].map { ($0, repo ?? mark.folder) }
                })
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
