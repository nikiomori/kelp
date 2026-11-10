import Core
import Foundation
import GRDB
import GitKit

// Source control, files and review comments: everything runs here, off the UI.

extension GitStatus: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.status(scm.folder(id), limit: FileChange.limit, remotes: scm.remotes)
    }
}
extension GitBranches: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.branches(scm.folder(id), remotes: scm.remotes)
    }
}
extension GitLineStats: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.lineStats(scm.folder(id), remotes: scm.remotes)
    }
}
/// `git.remote`'s push under its older name (the CLI's `kelp git push`, scripts): the same rules, the same code.
extension GitPush: Handled {
    private var op: GitRemoteOp { GitRemoteOp(id: id, op: "push") }
    var inWorkspace: String? { op.inWorkspace }
    var notForAgents: String? { op.notForAgents }
    func handle(_ scm: SourceControl) throws -> Done { try op.handle(scm) }
}

extension GitDiff: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        let workspace = try scm.store.worktree(named: id)
        var dir = workspace.path
        let src: DiffSource
        switch source ?? "all" {
        case "turn": (dir, src) = try scm.turnDiff(session: session, turn: turn)
        case "unstaged": src = .unstaged
        case "staged": src = .staged
        case "branch":
            src = .branch(
                base: try clientRef(base) ?? (try scm.store.repo(workspace.repoId)?.baseBranch ?? "main"))
        case "commit":
            guard let commit else { throw RPCError.invalidParams("missing commit") }
            src = .commit(try clientRef(commit) ?? "")
        default: src = .allUncommitted
        }
        return try Git.diff(
            dir, source: src, file: file, ignoreSpace: ignoreSpace == true, context: context ?? 3,
            remotes: scm.remotes)
    }
}

extension GitLog: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        let workspace = try scm.store.worktree(named: id)
        let base = all == true ? nil : try scm.store.repo(workspace.repoId)?.baseBranch
        return try Git.log(workspace.path, base: base, remotes: scm.remotes).map {
            Entry(hash: $0.hash, subject: $0.subject)
        }
    }
}

extension GitUnsynced: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.unsynced(scm.folder(id), limit: limit ?? 5, remotes: scm.remotes)
    }
}

extension GitStage: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        try Git.stage(scm.folder(id), files: files ?? [], remotes: scm.remotes)
        return Done()
    }
}
extension GitUnstage: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        try Git.unstage(scm.folder(id), files: files ?? [], remotes: scm.remotes)
        return Done()
    }
}

extension GitHunk: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        let workspace = try scm.store.worktree(named: id), rev = reverse == true
        let diff = try Git.diff(
            workspace.path, source: rev ? .staged : .unstaged, file: file, remotes: scm.remotes
        )
        .first
        guard let diff, let index = diff.shown(fingerprint: fingerprint, header: header, number: hunk) else {
            throw RPCError.invalidParams(
                rev
                    ? "The file changed since it was shown; nothing was unstaged."
                    : "The file changed since it was shown; nothing was staged.")
        }
        try Git.applyHunk(workspace.path, diff: diff, hunk: index, reverse: rev, remotes: scm.remotes)
        return Done()
    }
}

extension FileDiff {
    /// The hunk a caller means, staging or discarding it: with its fingerprint, the hunk as shown line for line; with
    /// its header, that one; else by number. nil when it isn't there any more (the file changed since it was shown).
    func shown(fingerprint: String?, header: String?, number: Int?) -> Int? {
        if let fingerprint { return hunks.firstIndex { $0.fingerprint == fingerprint } }
        if let header { return hunks.firstIndex { $0.header == header } }
        return number.flatMap { hunks.indices.contains($0) ? $0 : nil }
    }
}

extension GitCommit: Handled {
    func handle(_ scm: SourceControl) throws -> String {
        try Git.commit(
            scm.folder(id), message: message, all: all == true, amend: amend == true, remotes: scm.remotes
        )
    }
}

extension GitMerge: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try scm.merge(scm.store.worktree(named: id), keepConflicts: keepConflicts == true)
    }
}

extension GitSwitch: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        try Git.switchBranch(
            scm.folder(id), to: clientRef(branch) ?? "", create: create == true, remote: remote == true,
            remotes: scm.remotes)
        return Done()
    }
}

extension GitGraph: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        let graph = try Git.graph(scm.folder(id), limit: max(1, limit ?? 200), remotes: scm.remotes)
        return Result(commits: graph.commits, more: graph.more)
    }
}

extension GitCommitFiles: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.commitFiles(scm.folder(id), commit: clientRef(commit) ?? "", remotes: scm.remotes)
    }
}
extension GitCommitDetails: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.commitDetails(scm.folder(id), commit: clientRef(commit) ?? "", remotes: scm.remotes)
    }
}
extension GitDiscard: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        let path = try scm.folder(id)
        _ = try Git.discard(path, files: files ?? [], remotes: scm.remotes) { back in
            try scm.keepDiscard(.init(patch: back, hunk: false), folder: path, name: undo)
        }
        return Done()
    }
}
extension GitDiscardHunk: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        let worktree = try scm.store.worktree(named: id)
        // Found as `git.hunk` finds it, wherever it is in the file now; `header` always comes, so never by number.
        guard let diff = try Git.diff(worktree.path, source: .unstaged, file: file, remotes: scm.remotes).first,
            let hunk = diff.shown(fingerprint: fingerprint, header: header, number: nil)
        else {
            throw RPCError.invalidParams("The file changed since it was shown; nothing was discarded.")
        }
        // First: see Git.discard.
        try scm.keepDiscard(.init(patch: diff.patch(hunk: hunk), hunk: true), folder: worktree.path, name: undo)
        try Git.discardHunk(worktree.path, diff: diff, hunk: hunk, remotes: scm.remotes)
        return Done()
    }
}

extension GitUndoDiscard: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        let path = try scm.folder(id)
        let undone = try scm.undoDiscard(folder: path, name: undo) { discard in
            do {
                try Git.putBack(path, patch: discard.patch, hunk: discard.hunk, remotes: scm.remotes)
            } catch let partly
                as Git.PartlyPutBack
            {
                throw RPCError.invalidParams(
                    "\(partly.back) of \(partly.of) files were put back; the others changed since the discard "
                        + "(\(partly.why.trimmingCharacters(in: .whitespacesAndNewlines))).")
            } catch {
                let why = (error as? GitError)?.message ?? "\(error)"
                throw RPCError.invalidParams("Nothing was put back: the files changed since the discard (\(why)).")
            }
        }
        guard undone else { throw RPCError.invalidParams("There's no discard to undo here any more.") }
        return Done()
    }
}

extension GitRemoteOp: Handled {
    var inWorkspace: String? { id }   // a fetch, in an agent's own workspace
    /// A pull merges into a tree and a push publishes a branch: the user's, as commits are (`AgentRules`).
    var notForAgents: String? {
        op == "fetch"
            ? nil
            : "A \(op) is the user's: an agent fetches; it pulls and pushes with git in its own terminal, which the user sees."
    }
    func handle(_ scm: SourceControl) throws -> Done {
        guard let remote = Git.Remote(rawValue: op) else { throw RPCError.invalidParams("op: pull, push or fetch") }
        try Git.remote(scm.folder(id), remote, remotes: scm.remotes)
        return Done()
    }
}
extension GitStash: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        try Git.stash(scm.folder(id), pop: pop == true, remotes: scm.remotes)
        return Done()
    }
}

extension GitWebURL: Handled {
    func handle(_ scm: SourceControl) throws -> String {
        let last = end ?? start
        return try Git.webURL(
            path: path, lines: start.flatMap { s in last.map { min(s, $0)...max(s, $0) } }, remotes: scm.remotes)
    }
}

extension GitWebPages: Handled {
    func handle(_ scm: SourceControl) throws -> Pages? {
        let path = try scm.store.repoPath(worktreeId: worktreeId, repoId: repoId).1
        // no origin: nothing to link to
        guard let origin = try? Git.run(["remote", "get-url", "origin"], cwd: path, remotes: scm.remotes) else {
            return nil
        }
        return Git.webPages(remote: origin.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension FilesList: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try ProjectFiles.list(scm.folder(id), remotes: scm.remotes)
    }
}
extension FilesIgnored: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try ProjectFiles.ignored(scm.folder(id), folder: folder, remotes: scm.remotes)
    }
}
extension FilesSearch: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try ProjectFiles.search(
            scm.folder(id), query: query, regex: regex == true, caseSensitive: `case` == true,
            wholeWord: word == true,
            remotes: scm.remotes)
    }
}

extension Methods {
    static let gitMethods: [any Handled.Type] = [
        GitStatus.self, GitBranches.self, GitLineStats.self, GitPush.self, GitDiff.self, GitLog.self,
        GitUnsynced.self, GitStage.self, GitUnstage.self, GitHunk.self, GitCommit.self, GitMerge.self, GitSwitch.self,
        GitGraph.self,
        GitCommitFiles.self, GitCommitDetails.self, GitDiscard.self, GitUndoDiscard.self, GitRemoteOp.self,
        GitDiscardHunk.self, GitStash.self, GitWebURL.self, GitWebPages.self,
        FilesList.self, FilesIgnored.self, FilesSearch.self, CommentAdd.self, CommentList.self, CommentSetState.self,
        CommentSend.self
    ]
}
