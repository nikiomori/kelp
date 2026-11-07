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
extension GitPush: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        try Git.remote(scm.folder(id), .push, remotes: scm.remotes)
        return Done()
    }
}

extension GitDiff: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        let workspace = try scm.store.worktree(named: id)
        var dir = workspace.path
        let src: DiffSource
        switch source ?? "all" {
        case "turn":   // since the agent's last turn started, where it worked then (its own worktree, maybe)
            // A paused agent isn't woken: its turns are kept in the store.
            guard let sessionId = session, let rec = try scm.store.session(sessionId) else {
                throw RPCError.invalidParams("No such agent.")
            }
            let ls = scm.sessions.existing(sessionId)
            dir = ls?.turnDir ?? ls?.snapshot.cwd ?? rec.cwd
            if let turn {   // one turn of its history: up to the next one's start, or now for the newest
                let marks = try scm.store.turns(session: sessionId)
                guard let index = marks.firstIndex(where: { $0.id == turn }) else {
                    throw RPCError.invalidParams("No such turn of that agent.")
                }
                dir = marks[index].folder
                src = index > 0 ? .between(marks[index].tree, marks[index - 1].tree) : .since(tree: marks[index].tree)
            } else {
                // The one in memory, else the last kept (gone after the daemon restarted), in the folder it was taken in.
                if let base = ls?.turnBase {
                    src = .since(tree: base)
                } else if let last = try scm.store.turns(session: sessionId).first {
                    dir = last.folder
                    src = .since(tree: last.tree)
                } else {
                    throw RPCError.invalidParams("That agent hasn't started a turn yet.")
                }
            }
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
        // With its fingerprint, the hunk as shown line for line; with its header, that one; else by number.
        let index =
            fingerprint.map { f in diff?.hunks.firstIndex { $0.fingerprint == f } ?? -1 }
            ?? header.map { h in diff?.hunks.firstIndex { $0.header == h } ?? -1 } ?? hunk ?? -1
        guard let diff, diff.hunks.indices.contains(index) else {
            throw RPCError.invalidParams(
                rev
                    ? "The file changed since it was shown; nothing was unstaged."
                    : "The file changed since it was shown; nothing was staged.")
        }
        try Git.applyHunk(workspace.path, diff: diff, hunk: index, reverse: rev, remotes: scm.remotes)
        return Done()
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
        let workspace = try scm.store.worktree(named: id)
        guard let repo = try scm.store.repo(workspace.repoId) else { throw RPCError.invalidParams("no repo") }
        if try Git.isDirty(workspace.path, remotes: scm.remotes) {
            throw RPCError.invalidParams("worktree has uncommitted changes")
        }
        // The main checkout too: a merge (and the abort a conflict brings) must never touch the user's own work there.
        if Git.isMerging(repo.path, remotes: scm.remotes) {
            throw RPCError.invalidParams("The main checkout is in the middle of a merge. Finish or abort it first.")
        }
        if try Git.isDirty(repo.path, remotes: scm.remotes) {
            throw RPCError.invalidParams("The main checkout has uncommitted changes. Commit or stash them first.")
        }
        // The branch checked out in the workspace now (a switch makes the record stale), into the base and only the base.
        let branch = (try? Git.currentBranch(workspace.path, remotes: scm.remotes)) ?? workspace.branch
        // Detached: "HEAD" would merge the main checkout into itself ("Already up to date") and report success.
        guard branch != "HEAD" else {
            throw RPCError.invalidParams(
                "This workspace isn't on a branch (detached HEAD). Create a branch for its commits, then merge.")
        }
        let res = try Git.merge(
            branch: branch, into: repo.path, onto: repo.baseBranch, keepConflicts: keepConflicts == true,
            remotes: scm.remotes)
        return Result(merged: res.merged, conflicts: res.conflicts)
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
        guard let diff = try Git.diff(worktree.path, source: .unstaged, file: file, remotes: scm.remotes).first,
            diff.hunks.indices.contains(hunk),
            diff.hunks[hunk].header == header, fingerprint.map({ $0 == diff.hunks[hunk].fingerprint }) ?? true
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
                let why = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(error)"
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

extension CommentAdd: Handled {
    var reportsFor: String? { session }   // a comment names its own session's agent as author, not another's
    var signs: Bool { true }
    func handle(_ scm: SourceControl) throws -> DiffComment {
        // A path is one line: one with a break in it would be drawn under no file, and sent as lines of its own.
        guard !file.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) else {
            throw RPCError.invalidParams("A file's path has no line breaks or control characters.")
        }
        let workspace = try scm.store.worktree(named: id)
        let on = try clientRef(commit) ?? "HEAD"
        let full = try Git.run(
            ["rev-parse", "--verify", "-q", on + "^{commit}"], cwd: workspace.path, ok: [0, 1],
            remotes: scm.remotes
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)   // empty before the first commit
        if commit != nil, full.isEmpty { throw RPCError.invalidParams("No commit \(on) here.") }
        let head = String(full.prefix(12))
        let agent = session.flatMap { scm.sessions.existing($0)?.snapshot.agent }.flatMap {
            $0 == "shell" || $0 == "custom" ? nil : $0
        }
        // A program in a terminal (an agent typed into it, a script) is named too: only the window's own comments are the
        // user's, unframed when they're sent.
        let author =
            try agent.map { try scm.sessions.setup.manifest($0, command: nil).name }
            ?? session.map { _ in String(localized: "A program in a terminal") }
        let comment = DiffComment(
            worktreeId: workspace.id, file: file, startLine: start ?? 1, endLine: end ?? start ?? 1, quote: quote ?? "",
            text: text,
            side: side == "old" ? "old" : nil, commit: head.isEmpty ? nil : head, author: author,
            onCommit: commit == nil ? nil : full)
        try scm.store.save(comment)
        return comment
    }
}
extension CommentList: Handled {
    func handle(_ scm: SourceControl) throws -> Result { try scm.store.comments(worktree: id) }
}
extension CommentSetState: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        guard var comment = try scm.store.db.read({ try DiffComment.fetchOne($0, key: id) }) else {
            throw RPCError.invalidParams("no comment")
        }
        comment.state = DiffComment.State(rawValue: state) ?? .open
        try scm.store.save(comment)
        return Done()
    }
}
/// All open comments → one message into the agent's terminal.
extension CommentSend: Handled {
    var actsOn: String? { session }   // it types, with Enter: an agent sends only to itself and the sessions it started
    var typesInto: String? { session }   // a send (`SessionSend`, whose handler it calls past `allow`): not into a question
    func handle(_ scm: SourceControl) throws -> Int {
        let workspace = try scm.store.worktree(named: id)
        // Into an agent only: a shell would run each line of the message (another agent's findings, quoted code).
        // Its record, not only a running one: a paused agent is one too, and the send wakes it.
        guard
            try (scm.sessions.existing(session)?.snapshot ?? scm.store.session(session))?.isAgent == true
        else {
            throw RPCError.invalidParams("Comments go to an agent, not to a terminal.")
        }
        let wanted = only.map(Set.init)
        // Taken as it's marked sent, in one write: a second send at once (a double click, the CLI beside the window) finds
        // none of these open and types them in no second time. Put back if the send fails.
        let open = try scm.store.db.write { db -> [DiffComment] in
            let open = try DiffComment.filter(Column("worktreeId") == workspace.id).fetchAll(db)
                .filter { $0.state == .open && wanted?.contains($0.id) != false }
            for var comment in open {
                comment.state = .sent
                try comment.update(db)
            }
            return open
        }
        guard !open.isEmpty else { return 0 }
        do {
            _ = try SessionSend(id: session, text: Self.message(branch: workspace.branch, comments: open)).handle(
                scm.sessions)
        } catch {
            // Open again, those still sent (not one set otherwise meanwhile, nor one gone with its workspace); the send's
            // error is what's told, whatever this does.
            let ids = open.map(\.id)
            Log.store.attempt("putting back comments that weren't sent") {
                _ = try scm.store.db.write { db in
                    try DiffComment.filter(
                        ids.contains(Column("id")) && Column("state") == DiffComment.State.sent.rawValue
                    )
                    .updateAll(db, Column("state").set(to: DiffComment.State.open.rawValue))
                }
            }
            throw error
        }
        return open.count
    }

    /// File, lines, code quote, remark for each.
    private static func message(branch: String, comments: [DiffComment]) -> String {
        var body = "Review comments on branch \(branch). Please address each one:\n"
        for (index, comment) in comments.enumerated() {
            let range =
                comment.startLine == comment.endLine
                ? "\(comment.startLine)" : "\(comment.startLine)-\(comment.endLine)"
            let removed = comment.side == "old" ? " (removed lines, numbered as in the file before this change)" : ""
            let past = comment.onCommit.map { " (in commit \($0.prefix(12)), not the current changes)" } ?? ""
            var entry = "\(comment.file):\(range)\(removed)\(past)\n"
            for line in comment.quote.split(separator: "\n", omittingEmptySubsequences: false) {
                entry += "   > \(line)\n"
            }
            entry += "   " + comment.text
            // Another agent's finding is data to weigh, not the user's word: it may quote what a pull request said. All
            // of it, where and what it quotes too: each is what that agent wrote.
            body +=
                "\n\(index + 1). " + (comment.author.map { Untrusted.frame(entry, what: "\($0)'s finding") } ?? entry)
                + "\n"
        }
        return body
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
