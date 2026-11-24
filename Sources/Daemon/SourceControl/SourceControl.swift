import Core
import Foundation
import GitKit

/// What the git handlers are given (GitHandlers.swift and CommentHandlers.swift: source control, files and review
/// comments). It holds the workspaces' records, how to reach a remote project's host, what discards threw away, and the
/// sessions that a turn's diff reads and that a review is sent to. It holds less than all of `Sessions`, because a git
/// handler itself starts, wakes and ends no session.
struct SourceControl: Sendable {
    let root: URL
    let store: Store
    let remotes: Remotes
    let live: SessionTable   // a turn's diff is read where its agent works now
    let setup: SessionSetup   // names the agent for a commit's trailer and a comment's author
    /// Types into an agent as `session.send` does, on the agent's lane and waking it. That is the one thing comments
    /// do to a session.
    let send: @Sendable (SessionSend) throws -> Void

    /// The folder of the workspace a client named, or of a chat's own branch (`Store.gitPlace`).
    func folder(_ worktreeId: String) throws -> String { try store.gitPlace(named: worktreeId).path }

    /// Returns what an agent's turn changed, and the folder it worked in then (maybe its own worktree). With `turn`, a
    /// turn from the agent's history, the diff runs from that turn's start up to the next turn's start, or up to now
    /// for the newest. Without `turn`, it runs from the start of the agent's last turn. A paused agent isn't woken,
    /// because its turns are kept in the store.
    func turnDiff(session: String?, turn: String?) throws -> (folder: String, source: DiffSource) {
        guard let sessionId = session else {
            throw RPCError.invalidParams("Say whose turn to show: an agent's session.")
        }
        guard let rec = try store.session(sessionId) else { throw RPCError.noSession(sessionId) }
        let ls = live[sessionId]
        if let turn {
            let marks = try store.turns(session: sessionId)
            guard let index = marks.firstIndex(where: { $0.id == turn }) else {
                throw RPCError.invalidParams("No such turn of that agent.")
            }
            let mark = marks[index]
            return (mark.folder, index > 0 ? .between(mark.tree, marks[index - 1].tree) : .since(tree: mark.tree))
        }
        // Uses the turn's base in memory, or else the last one kept (the memory is gone after the daemon restarted),
        // in the folder where it was taken.
        if let base = ls?.turnBase { return (ls?.turnDir ?? ls?.snapshot.cwd ?? rec.cwd, .since(tree: base)) }
        guard let last = try store.turns(session: sessionId).first else {
            throw RPCError.invalidParams("That agent hasn't started a turn yet.")
        }
        return (last.folder, .since(tree: last.tree))
    }

    /// Merges the branch checked out in `workspace` now (a switch makes the record stale) into its project's base
    /// branch, and only the base, in the main checkout. It is refused while either checkout has uncommitted changes, or
    /// while the main one is in the middle of a merge.
    func merge(_ workspace: Worktree, keepConflicts: Bool) throws -> GitMerge.Result {
        guard let repo = try store.repo(workspace.repoId) else { throw RPCError.noProject(workspace.repoId) }
        if try Git.isDirty(workspace.path, remotes: remotes) {
            throw RPCError.invalidParams(
                "The workspace has uncommitted changes: commit or discard them, then merge.")
        }
        // The main checkout is checked too, because a merge (and the abort a conflict brings) must never touch the
        // user's own work there.
        if Git.isMerging(repo.path, remotes: remotes) {
            throw RPCError.invalidParams("The main checkout is in the middle of a merge. Finish or abort it first.")
        }
        if try Git.isDirty(repo.path, remotes: remotes) {
            throw RPCError.invalidParams("The main checkout has uncommitted changes. Commit or stash them first.")
        }
        let branch = (try? Git.currentBranch(workspace.path, remotes: remotes)) ?? workspace.branch
        // On a detached HEAD, "HEAD" would merge the main checkout into itself ("Already up to date") and report
        // success.
        guard branch != "HEAD" else {
            throw RPCError.invalidParams(
                "This workspace isn't on a branch (detached HEAD). Create a branch for its commits, then merge.")
        }
        let res = try Git.merge(
            branch: branch, into: repo.path, onto: repo.baseBranch, keepConflicts: keepConflicts, remotes: remotes)
        return GitMerge.Result(merged: res.merged, conflicts: res.conflicts)
    }

    /// The folder that keeps what discards threw away, for a minute (`git.undoDiscard`). Each discard is a file named
    /// by its folder and the name the caller gave it, so the Undo still works after the daemon was upgraded in place,
    /// restarted or crashed.
    var discards: URL { Self.discards(root) }
    static func discards(_ root: URL) -> URL { root.appendingPathComponent("discarded") }
    private func discardFile(folder: String, name: String?) -> URL {
        discards.appendingPathComponent(Workspaces.digest(folder + "\0" + (name ?? "")) + ".json")
    }
    /// Keeps `discard` under `name` for `folder`, and drops the discards past their minute. It runs before the files
    /// change (`Git.discard`'s `keep`), so a discard whose Undo can't be kept (on a full disk, say) isn't made.
    func keepDiscard(_ discard: Discarded, folder: String, name: String?) throws {
        Self.sweepDiscards(root)
        do {
            try FileManager.default.createDirectory(at: discards, withIntermediateDirectories: true)
            try JSONEncoder().encode(discard).write(to: discardFile(folder: folder, name: name), options: .atomic)
        } catch {
            throw RPCError.internalError(
                "Nothing was discarded: its Undo couldn't be kept (\(error.localizedDescription)).")
        }
        // The file is swept after its minute even when nothing else is discarded, because a patch can be large.
        let root = root
        DispatchQueue.global().asyncAfter(deadline: .now() + 61) { Self.sweepDiscards(root) }
    }
    /// Hands the discard kept under `name` to `putBack`, if its minute isn't over. The file is moved aside first, so an
    /// Undo happens once and two Undos can't both have it. If `putBack` throws, the discard is kept again for another
    /// try within its minute. Returns false when there is no discard.
    func undoDiscard(folder: String, name: String?, _ putBack: (Discarded) throws -> Void) throws -> Bool {
        let file = discardFile(folder: folder, name: name), taken = file.appendingPathExtension(UUID().uuidString)
        guard rename(file.path, taken.path) == 0 else { return false }
        let discard = Log.store.attempt("reading a discard") {
            try JSONDecoder().decode(Discarded.self, from: Data(contentsOf: taken))
        }
        guard let discard, discard.at.timeIntervalSinceNow > -60 else {
            unlink(taken.path)
            return false
        }
        do { try putBack(discard) } catch {
            // When a newer discard has taken the name, the newer one stays.
            if renamex_np(taken.path, file.path, UInt32(RENAME_EXCL)) != 0 { unlink(taken.path) }
            throw error
        }
        unlink(taken.path)
        return true
    }
    /// Drops the discards past their minute. It also runs at start, for what an earlier daemon kept.
    static func sweepDiscards(_ root: URL) {
        let old = Date().timeIntervalSince1970 - 60, discards = discards(root)
        for name in FileManager.default.enumerator(atPath: discards.path)?.allObjects as? [String] ?? [] {
            let path = discards.appendingPathComponent(name).path
            if let at = FileManager.default.modified(path)?.timeIntervalSince1970, at < old { unlink(path) }
        }
    }
    struct Discarded: Codable, Sendable {
        var at = Date()
        var patch: Data, hunk: Bool
    }
}
