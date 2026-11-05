import Foundation
import Core
import GitKit

// Source control, files and review comments: everything runs here, off the UI.

extension GitStatus: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        try Git.status(workspaces.folder(id), limit: FileChange.limit, remotes: workspaces.remotes)
    }
}
extension GitBranches: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result { try Git.branches(workspaces.folder(id), remotes: workspaces.remotes) }
}
extension GitLineStats: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result { try Git.lineStats(workspaces.folder(id), remotes: workspaces.remotes) }
}
extension GitPush: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        try Git.remote(workspaces.folder(id), .push, remotes: workspaces.remotes)
        return Done()
    }
}

extension GitDiff: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        let w = try workspaces.store.worktree(named: id)
        var dir = w.path
        let src: DiffSource
        switch source ?? "all" {
        case "turn":   // since the agent's last turn started, where it worked then (its own worktree, maybe)
            // A paused agent isn't woken: its turns are kept in the store.
            guard let s = session, let rec = try workspaces.store.session(s) else { throw RPCError.invalidParams("No such agent.") }
            let ls = workspaces.sessions.existing(s)
            dir = ls?.turnDir ?? ls?.snapshot.cwd ?? rec.cwd
            if let turn {   // one turn of its history: up to the next one's start, or now for the newest
                let marks = try workspaces.store.turns(session: s)
                guard let i = marks.firstIndex(where: { $0.id == turn }) else { throw RPCError.invalidParams("No such turn of that agent.") }
                dir = marks[i].folder
                src = i > 0 ? .between(marks[i].tree, marks[i - 1].tree) : .since(tree: marks[i].tree)
            } else {
                // The one in memory, else the last kept (gone after the daemon restarted), in the folder it was taken in.
                if let base = ls?.turnBase {
                    src = .since(tree: base)
                } else if let last = try workspaces.store.turns(session: s).first {
                    dir = last.folder; src = .since(tree: last.tree)
                } else {
                    throw RPCError.invalidParams("That agent hasn't started a turn yet.")
                }
            }
        case "unstaged": src = .unstaged
        case "staged": src = .staged
        case "branch": src = .branch(base: try clientRef(base) ?? (try workspaces.store.repo(w.repoId)?.baseBranch ?? "main"))
        case "commit":
            guard let commit else { throw RPCError.invalidParams("missing commit") }
            src = .commit(try clientRef(commit) ?? "")
        default: src = .allUncommitted
        }
        return try Git.diff(dir, source: src, file: file, ignoreSpace: ignoreSpace == true, context: context ?? 3,
                            remotes: workspaces.remotes)
    }
}

extension GitLog: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        let w = try workspaces.store.worktree(named: id)
        let base = all == true ? nil : try workspaces.store.repo(w.repoId)?.baseBranch
        return try Git.log(w.path, base: base, remotes: workspaces.remotes).map { Entry(hash: $0.hash, subject: $0.subject) }
    }
}

extension GitUnsynced: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        try Git.unsynced(workspaces.folder(id), limit: limit ?? 5, remotes: workspaces.remotes)
    }
}

extension GitStage: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        try Git.stage(workspaces.folder(id), files: files ?? [], remotes: workspaces.remotes)
        return Done()
    }
}
extension GitUnstage: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        try Git.unstage(workspaces.folder(id), files: files ?? [], remotes: workspaces.remotes)
        return Done()
    }
}

extension GitHunk: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        let w = try workspaces.store.worktree(named: id), rev = reverse == true
        let diff = try Git.diff(w.path, source: rev ? .staged : .unstaged, file: file, remotes: workspaces.remotes).first
        // With its fingerprint, the hunk as shown line for line; with its header, that one; else by number.
        let i = fingerprint.map { f in diff?.hunks.firstIndex { $0.fingerprint == f } ?? -1 }
            ?? header.map { h in diff?.hunks.firstIndex { $0.header == h } ?? -1 } ?? hunk ?? -1
        guard let diff, diff.hunks.indices.contains(i) else {
            throw RPCError.invalidParams(rev ? "The file changed since it was shown; nothing was unstaged."
                                             : "The file changed since it was shown; nothing was staged.")
        }
        try Git.applyHunk(w.path, diff: diff, hunk: i, reverse: rev, remotes: workspaces.remotes)
        return Done()
    }
}

extension GitCommit: Handled {
    func handle(_ workspaces: Workspaces) throws -> String {
        try Git.commit(workspaces.folder(id), message: message, all: all == true, amend: amend == true, remotes: workspaces.remotes)
    }
}

extension GitMerge: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        let w = try workspaces.store.worktree(named: id)
        guard let r = try workspaces.store.repo(w.repoId) else { throw RPCError.invalidParams("no repo") }
        if try Git.isDirty(w.path, remotes: workspaces.remotes) { throw RPCError.invalidParams("worktree has uncommitted changes") }
        // The main checkout too: a merge (and the abort a conflict brings) must never touch the user's own work there.
        if Git.isMerging(r.path, remotes: workspaces.remotes) {
            throw RPCError.invalidParams("The main checkout is in the middle of a merge. Finish or abort it first.")
        }
        if try Git.isDirty(r.path, remotes: workspaces.remotes) {
            throw RPCError.invalidParams("The main checkout has uncommitted changes. Commit or stash them first.")
        }
        // The branch checked out in the workspace now (a switch makes the record stale), into the base and only the base.
        let branch = (try? Git.currentBranch(w.path, remotes: workspaces.remotes)) ?? w.branch
        // Detached: "HEAD" would merge the main checkout into itself ("Already up to date") and report success.
        guard branch != "HEAD" else {
            throw RPCError.invalidParams("This workspace isn't on a branch (detached HEAD). Create a branch for its commits, then merge.")
        }
        let res = try Git.merge(branch: branch, into: r.path, onto: r.baseBranch, keepConflicts: keepConflicts == true, remotes: workspaces.remotes)
        return Result(merged: res.merged, conflicts: res.conflicts)
    }
}

extension GitSwitch: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        try Git.switchBranch(workspaces.folder(id), to: clientRef(branch) ?? "", create: create == true, remote: remote == true, remotes: workspaces.remotes)
        return Done()
    }
}

extension GitGraph: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        let g = try Git.graph(workspaces.folder(id), limit: max(1, limit ?? 200), remotes: workspaces.remotes)
        return Result(commits: g.commits, more: g.more)
    }
}

extension GitCommitFiles: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        try Git.commitFiles(workspaces.folder(id), commit: clientRef(commit) ?? "", remotes: workspaces.remotes)
    }
}
extension GitCommitDetails: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        try Git.commitDetails(workspaces.folder(id), commit: clientRef(commit) ?? "", remotes: workspaces.remotes)
    }
}
extension GitDiscard: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        let path = try workspaces.folder(id)
        let back = try Git.discard(path, files: files ?? [], remotes: workspaces.remotes)
        workspaces.keepDiscard(.init(patch: back, hunk: false), folder: path, name: undo)
        return Done()
    }
}
extension GitUndoDiscard: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        let path = try workspaces.folder(id)
        guard let d = workspaces.takeDiscard(folder: path, name: undo) else {
            throw RPCError.invalidParams("There's no discard to undo here any more.")
        }
        do { try Git.putBack(path, patch: d.patch, hunk: d.hunk, remotes: workspaces.remotes) } catch {
            let why = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(error)"
            throw RPCError.invalidParams("Nothing was put back: the files changed since the discard (\(why)).")
        }
        return Done()
    }
}

extension GitRemoteOp: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard let o = Git.Remote(rawValue: op) else { throw RPCError.invalidParams("op: pull, push or fetch") }
        try Git.remote(workspaces.folder(id), o, remotes: workspaces.remotes)
        return Done()
    }
}
extension GitStash: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        try Git.stash(workspaces.folder(id), pop: pop == true, remotes: workspaces.remotes)
        return Done()
    }
}

extension GitWebURL: Handled {
    func handle(_ workspaces: Workspaces) throws -> String {
        let last = end ?? start
        return try Git.webURL(path: path, lines: start.flatMap { s in last.map { min(s, $0)...max(s, $0) } }, remotes: workspaces.remotes)
    }
}

extension GitWebPages: Handled {
    func handle(_ workspaces: Workspaces) throws -> Pages? {
        let path = try workspaces.store.repoPath(worktreeId: worktreeId, repoId: repoId).1
        // no origin: nothing to link to
        guard let origin = try? Git.run(["remote", "get-url", "origin"], cwd: path, remotes: workspaces.remotes) else { return nil }
        return Git.webPages(remote: origin.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension FilesList: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result { try ProjectFiles.list(workspaces.folder(id), remotes: workspaces.remotes) }
}
extension FilesIgnored: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result { try ProjectFiles.ignored(workspaces.folder(id), folder: folder, remotes: workspaces.remotes) }
}
extension FilesSearch: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        try ProjectFiles.search(workspaces.folder(id), query: query, regex: regex == true, caseSensitive: `case` == true, wholeWord: word == true,
                                remotes: workspaces.remotes)
    }
}

extension CommentAdd: Handled {
    var reportsFor: String? { session }   // a comment names its own session's agent as author, not another's
    func handle(_ workspaces: Workspaces) throws -> DiffComment {
        let w = try workspaces.store.worktree(named: id)
        let on = try clientRef(commit) ?? "HEAD"
        let full = try Git.run(["rev-parse", "--verify", "-q", on + "^{commit}"], cwd: w.path, ok: [0, 1], remotes: workspaces.remotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)   // empty before the first commit
        if commit != nil, full.isEmpty { throw RPCError.invalidParams("No commit \(on) here.") }
        let head = String(full.prefix(12))
        let agent = session.flatMap { workspaces.sessions.existing($0)?.snapshot.agent }.flatMap { $0 == "shell" || $0 == "custom" ? nil : $0 }
        let author = try agent.map { try workspaces.sessions.manifest($0, command: nil).name }
        let c = DiffComment(worktreeId: w.id, file: file, startLine: start ?? 1, endLine: end ?? start ?? 1, quote: quote ?? "", text: text,
                            side: side == "old" ? "old" : nil, commit: head.isEmpty ? nil : head, author: author,
                            onCommit: commit == nil ? nil : full)
        try workspaces.store.save(c)
        return c
    }
}
extension CommentList: Handled { func handle(_ workspaces: Workspaces) throws -> Result { try workspaces.store.comments(worktree: id) } }
extension CommentSetState: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard var c = try workspaces.store.db.read({ try DiffComment.fetchOne($0, key: id) }) else { throw RPCError.invalidParams("no comment") }
        c.state = DiffComment.State(rawValue: state) ?? .open
        try workspaces.store.save(c)
        return Done()
    }
}
/// All open comments → one message into the agent's terminal.
extension CommentSend: Handled {
    var actsOn: String? { session }   // it types, with Enter: an agent sends only to itself and the sessions it started
    func handle(_ workspaces: Workspaces) throws -> Int {
        let w = try workspaces.store.worktree(named: id)
        // Into an agent only: a shell would run each line of the message (another agent's findings, quoted code).
        guard workspaces.sessions.existing(session)?.snapshot.isAgent == true else {
            throw RPCError.invalidParams("Comments go to an agent, not to a terminal.")
        }
        let wanted = only.map(Set.init)
        let open = try workspaces.store.comments(worktree: w.id).filter { $0.state == .open && wanted?.contains($0.id) != false }
        guard !open.isEmpty else { return 0 }
        _ = try SessionSend(id: session, text: Self.message(branch: w.branch, comments: open)).handle(workspaces.sessions)
        for var c in open { c.state = .sent; try workspaces.store.save(c) }
        return open.count
    }

    /// File, lines, code quote, remark for each.
    private static func message(branch: String, comments: [DiffComment]) -> String {
        var s = "Review comments on branch \(branch). Please address each one:\n"
        for (i, c) in comments.enumerated() {
            let range = c.startLine == c.endLine ? "\(c.startLine)" : "\(c.startLine)-\(c.endLine)"
            let removed = c.side == "old" ? " (removed lines, numbered as in the file before this change)" : ""
            let past = c.onCommit.map { " (in commit \($0.prefix(12)), not the current changes)" } ?? ""
            s += "\n\(i + 1). \(c.file):\(range)\(removed)\(past)\n"
            for l in c.quote.split(separator: "\n", omittingEmptySubsequences: false) { s += "   > \(l)\n" }
            // Another agent's finding is data to weigh, not the user's word: it may quote what a pull request said.
            s += "   " + (c.author.map { Untrusted.frame(c.text, what: "\($0)'s finding") } ?? c.text) + "\n"
        }
        return s
    }
}

extension Methods {
    static let gitMethods: [any Handled.Type] = [GitStatus.self, GitBranches.self, GitLineStats.self, GitPush.self, GitDiff.self, GitLog.self,
        GitUnsynced.self, GitStage.self, GitUnstage.self, GitHunk.self, GitCommit.self, GitMerge.self, GitSwitch.self, GitGraph.self,
        GitCommitFiles.self, GitCommitDetails.self, GitDiscard.self, GitUndoDiscard.self, GitRemoteOp.self, GitStash.self, GitWebURL.self, GitWebPages.self,
        FilesList.self, FilesIgnored.self, FilesSearch.self, CommentAdd.self, CommentList.self, CommentSetState.self, CommentSend.self]
}
