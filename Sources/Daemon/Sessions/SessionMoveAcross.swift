import Agents
import Core
import Foundation
import GitKit

/// What moving a chat across machines is handed: the workspaces, for the worktree it goes into, and their sessions.
struct ChatMoves {
    let workspaces: Workspaces
}

extension SessionMoveAcross: Handled {
    func handle(_ moves: ChatMoves) throws -> Session {
        let workspaces = moves.workspaces, store = workspaces.store, remotes = workspaces.remotes,
            sessions = workspaces.sessions
        guard let old = try store.session(id), let wid = old.worktreeId else {
            throw RPCError.invalidParams("no session")
        }
        let from = try store.worktree(named: wid)
        guard let fromRepo = try store.repo(from.repoId), let toRepo = try store.repo(repoId), toRepo.id != fromRepo.id
        else { throw RPCError.invalidParams("Pick another copy of this project to move the chat to.") }
        guard !(try ChatMove.roots(from.path, remotes).isDisjoint(with: ChatMove.roots(toRepo.path, remotes))) else {
            throw RPCError.invalidParams("\(toRepo.name) isn't a copy of this project: they share no first commit.")
        }
        let branch = try ChatMove.carry(
            from: from.path, base: fromRepo.baseBranch, to: toRepo.path, name: from.branch, remotes: remotes)
        let made = try workspaces.createBranchWorkspace(
            in: toRepo, WorktreeCreate(repoId: toRepo.id, branch: branch, note: from.note, tabs: false, existing: true))
        try ChatMove.carryUncommitted(from: from.path, to: made.worktree.path, remotes: remotes)
        let next = try SessionHandoff(
            id: old.id, agent: old.agent,
            prompt: "Continue the task where the previous agent left off: check what's done, then finish it."
        )
        .start(from: old, in: made.worktree.path, worktreeId: made.worktree.id, sessions)
        sessions.pauseOne(old.id)
        return next
    }
}

/// What moving a chat carries from one copy of a project to another, either of them here or on a host.
enum ChatMove {
    /// A repository's first commits: two copies of one project share them.
    static func roots(_ dir: String, _ remotes: Remotes) throws -> Set<String> {
        Set(
            try Git.run(["rev-list", "--max-parents=0", "HEAD"], cwd: dir, remotes: remotes).split(separator: "\n")
                .map(String.init))
    }

    /// `from`'s HEAD as a new branch of `to`, named `name` (`name-2`… when taken): its commits in a bundle of what `to`
    /// hasn't got (since `base`, when `to` has that; all of them otherwise). Answers the branch's name.
    static func carry(from: String, base: String, to: String, name: String, remotes: Remotes) throws -> String {
        var branch = name, number = 2
        while Git.branchExists(to, branch, remotes: remotes) {
            branch = "\(name)-\(number)"
            number += 1
        }
        let head = try Git.line(["rev-parse", "HEAD"], cwd: from, remotes: remotes)
        if has(to, head, remotes) {
            try Git.run(["branch", branch, head], cwd: to, remotes: remotes)
            return branch
        }
        let since = try Git.line(["merge-base", "HEAD", base], cwd: from, ok: [0, 1], remotes: remotes)
        // `to` may not have fetched what `from` started from: asked once, not required.
        if !since.isEmpty, !has(to, since, remotes) {
            _ = Git.succeeds(["fetch", "-q", "origin"], cwd: to, remotes: remotes)
        }
        let range = !since.isEmpty && has(to, since, remotes) ? ["HEAD", "^" + since] : ["HEAD"]
        let bundle = try Git.runData(["bundle", "create", "-"] + range, cwd: from, remotes: remotes)
        let file = try place(bundle, at: to, remotes)
        defer { drop(file, at: to, remotes) }
        try Git.run(["fetch", "-q", file, "+HEAD:refs/heads/" + branch], cwd: to, remotes: remotes)
        return branch
    }

    /// `from`'s uncommitted changes, new files too (not ones that look like secrets: `snapshotTree`), applied in `to`.
    static func carryUncommitted(from: String, to: String, remotes: Remotes) throws {
        let tree = try Git.snapshotTree(from, remotes: remotes)
        let patch = try Git.run(["diff", "--binary", "HEAD", tree], cwd: from, remotes: remotes)
        guard !patch.isEmpty else { return }
        try Git.run(["apply", "--binary", "-"], cwd: to, stdin: patch, remotes: remotes)
    }

    private static func has(_ dir: String, _ commit: String, _ remotes: Remotes) -> Bool {
        Git.succeeds(["cat-file", "-e", commit + "^{commit}"], cwd: dir, remotes: remotes)
    }

    /// `data` in a temporary file on `dir`'s side (this Mac, or its host): the file's path there.
    private static func place(_ data: Data, at dir: String, _ remotes: Remotes) throws -> String {
        if let host = remotes.of(dir) {
            return String(
                decoding: try host.run(#"f="$(mktemp)" && cat > "$f" && printf %s "$f""#, stdin: data, timeLimit: 120),
                as: UTF8.self)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-move-\(UUID().uuidString)")
        try data.write(to: file)
        return file.path
    }

    private static func drop(_ path: String, at dir: String, _ remotes: Remotes) {
        Log.session.attempt("removing a moved chat's bundle") {
            if let host = remotes.of(dir) {
                try host.run("rm -f -- " + ShellQuote.word(path))
            } else {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
