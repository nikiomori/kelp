import Core
import Foundation
import GRDB
import GitKit

// The handlers for source control and the project's files. All of them run in the daemon, off the UI.

extension GitStatus: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try scm.each(scm.folder(id)) { try Git.status($0, limit: FileChange.limit, remotes: scm.remotes) }
            .flatMap { repo in repo.value.map { $0.under(repo.name) } }
    }
}
extension GitBranches: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.branches(scm.folder(id), remotes: scm.remotes)
    }
}
extension GitLineStats: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.lineStats(scm.folder(id), remotes: scm.remotes)
    }
}
/// The push of `git.remote` under its older name, for the CLI's `kelp git push` and for scripts. It follows the same
/// rules and runs the same code.
extension GitPush: Handled {
    private var op: GitRemoteOp { GitRemoteOp(id: id, op: .push) }
    var fence: Fence { op.fence }
    func handle(_ scm: SourceControl) throws -> Done { try op.handle(scm) }
}

extension GitDiff: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        let workspace = try scm.store.gitPlace(named: id)
        var dir = workspace.path
        let src: DiffSource
        switch source ?? .all {
        case .tidy:
            // Compares Tidy Up's copies with the files now. This diff uses the instruction files Kelp kept, not the
            // workspace's git.
            guard let (run, info) = TidyRuns.open(id, root: scm.root) else { return [] }
            return try TidyRuns.diff(run, info, remotes: scm.remotes).filter { file == nil || $0.path == file }
        case .turn: (dir, src) = try scm.turnDiff(session: session, turn: turn)
        case .unstaged: src = .unstaged
        case .staged: src = .staged
        case .branch:
            src = .branch(
                base: try clientRef(base) ?? (try scm.store.repo(workspace.repoId)?.baseBranch ?? "main"))
        case .commit:
            guard let commit else { throw RPCError.invalidParams("missing commit") }
            src = .commit(try clientRef(commit) ?? "")
        case .all: src = .allUncommitted
        }
        if (source ?? .all) != .turn, scm.repos(in: dir) != nil { return try several(scm, dir, src) }
        return try Git.diff(
            dir, source: src, file: file, ignoreSpace: ignoreSpace == true, context: context ?? 3,
            remotes: scm.remotes)
    }
}

extension GitLineOrigin: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        let (folder, file) = try scm.place(scm.store.gitPlace(named: worktreeId).path, self.file)
        let head = try Git.head(folder, remotes: scm.remotes)
        // Only turns begun on this HEAD count, because older turns' changes are in commits now, and those commits say
        // who made them.
        let marks = try scm.store.turns(folder: folder).filter { head != nil && $0.head == head }
        let agents = try marks.map { mark in
            let agent = try scm.store.session(mark.session)?.agent
            return Log.store.attempt("an agent's name for a line's turn") {
                try scm.setup.manifest(agent, command: nil).name
            } ?? "Agent"
        }
        let steps = zip(marks, agents).map { (tree: $0.tree, author: $1, message: $0.prompt) }
        guard let found = try Git.lineOrigin(folder, file: file, line: line, steps: steps, remotes: scm.remotes) else {
            return nil
        }
        return Origin(
            commit: found.commit, author: found.author, date: found.date, summary: found.summary,
            turn: found.step.map { marks[$0] })
    }
}

extension GitLog: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        let workspace = try scm.store.gitPlace(named: id)
        let base = all == true ? nil : try scm.store.repo(workspace.repoId)?.baseBranch
        return try Git.log(workspace.path, base: base, remotes: scm.remotes).map {
            Entry(hash: $0.hash, subject: $0.subject)
        }
    }
}

extension GitUnsynced: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.unsynced(scm.folder(id), limit: limit ?? 5, remotes: scm.remotes)
    }
}

extension GitStage: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        for place in try scm.places(scm.folder(id), files ?? []) {
            try Git.stage(place.folder, files: place.files, remotes: scm.remotes)
        }
        return Done()
    }
}
extension GitUnstage: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        for place in try scm.places(scm.folder(id), files ?? []) {
            try Git.unstage(place.folder, files: place.files, remotes: scm.remotes)
        }
        return Done()
    }
}

extension GitHunk: Handled {
    // Staging or unstaging a hunk writes the index, so an agent may do it only in its own workspaces.
    static let agents = AgentAccess.acts
    func handle(_ scm: SourceControl) throws -> Done {
        let rev = reverse == true
        let (folder, file) = try scm.place(scm.store.gitPlace(named: id).path, self.file)
        let diff = try Git.diff(folder, source: rev ? .staged : .unstaged, file: file, remotes: scm.remotes).first
        guard let diff, let index = diff.shown(fingerprint: fingerprint, header: header, number: hunk) else {
            throw RPCError.invalidParams(
                rev
                    ? "The file changed since it was shown; nothing was unstaged."
                    : "The file changed since it was shown; nothing was staged.")
        }
        try Git.applyHunk(folder, diff: diff, hunk: index, reverse: rev, remotes: scm.remotes)
        return Done()
    }
}

extension FileDiff {
    /// Returns the index of the hunk that a caller means to stage or discard. With a fingerprint, it is the hunk as
    /// shown, line for line. With a header, it is the hunk with that header. Otherwise it is found by number. Returns
    /// nil when the hunk isn't there any more, because the file changed since it was shown.
    func shown(fingerprint: String?, header: String?, number: Int?) -> Int? {
        if let fingerprint { return hunks.firstIndex { $0.fingerprint == fingerprint } }
        if let header { return hunks.firstIndex { $0.header == header } }
        return number.flatMap { hunks.indices.contains($0) ? $0 : nil }
    }
}

extension GitCommit: Handled {
    /// In a folder of repositories (`RepoKey`), one message makes a commit in each repository that has something to
    /// commit: what is staged there, or with `all` every change. It returns each one's name and hash.
    func handle(_ scm: SourceControl) throws -> String {
        let folder = try scm.folder(id)
        guard let names = scm.repos(in: folder) else {
            return try Git.commit(
                folder, message: message, all: all == true, amend: amend == true, remotes: scm.remotes)
        }
        return try scm.commitInEach(folder, names, message: message, all: all == true, amend: amend == true)
    }
}

extension GitMerge: Handled {
    func handle(_ scm: SourceControl) throws -> Result {
        try scm.merge(scm.store.gitPlace(named: id), keepConflicts: keepConflicts == true)
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

extension GitCommitAct: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        try Git.act(op, on: clientRef(commit) ?? "", branch: branch, in: scm.folder(worktreeId), remotes: scm.remotes)
        return Done()
    }
}

extension GitGraph: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        let graph = try Git.graph(scm.folder(id), limit: max(1, limit ?? 200), remotes: scm.remotes)
        return Result(commits: graph.commits, more: graph.more)
    }
}

extension GitCommitFiles: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.commitFiles(scm.folder(id), commit: clientRef(commit) ?? "", remotes: scm.remotes)
    }
}
extension GitCommitDetails: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try Git.commitDetails(scm.folder(id), commit: clientRef(commit) ?? "", remotes: scm.remotes)
    }
}
extension GitDiscard: Handled {
    /// What is thrown away is kept by the repository it is put back in (`GitUndoDiscard`).
    func handle(_ scm: SourceControl) throws -> Done {
        for place in try scm.places(scm.folder(id), files ?? []) {
            _ = try Git.discard(place.folder, files: place.files, remotes: scm.remotes) { back in
                try scm.keepDiscard(.init(patch: back, hunk: false), folder: place.folder, name: undo)
            }
        }
        return Done()
    }
}
extension GitDiscardHunk: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        let (folder, file) = try scm.place(scm.store.gitPlace(named: id).path, self.file)
        // The hunk is found as `git.hunk` finds it, wherever it is in the file now. `header` always comes, so the
        // hunk is never found by number.
        guard let diff = try Git.diff(folder, source: .unstaged, file: file, remotes: scm.remotes).first,
            let hunk = diff.shown(fingerprint: fingerprint, header: header, number: nil)
        else {
            throw RPCError.invalidParams("The file changed since it was shown; nothing was discarded.")
        }
        // The patch is kept before anything changes, as Git.discard does, so nothing is thrown away unkept.
        try scm.keepDiscard(.init(patch: diff.patch(hunk: hunk), hunk: true), folder: folder, name: undo)
        try Git.discardHunk(folder, diff: diff, hunk: hunk, remotes: scm.remotes)
        return Done()
    }
}

extension GitUndoDiscard: Handled {
    /// In a folder of repositories, each one puts back what it kept under the name.
    func handle(_ scm: SourceControl) throws -> Done {
        var undone = false
        for place in try scm.places(scm.folder(id), []) where try putBack(scm, place.folder) { undone = true }
        guard undone else { throw RPCError.invalidParams("There's no discard to undo here any more.") }
        return Done()
    }

    private func putBack(_ scm: SourceControl, _ path: String) throws -> Bool {
        try scm.undoDiscard(folder: path, name: undo) { discard in
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
    }
}

extension GitRemoteOp: Handled {
    static let agents = AgentAccess.reads
    /// An agent may fetch, in its own workspace. A pull merges into a tree and a push publishes a branch, so both are
    /// the user's, as commits are (`AgentRules`).
    var fence: Fence {
        Fence(
            inWorkspace: id,
            notForAgents: op == .fetch
                ? nil
                : "A \(op) is the user's: an agent fetches; it pulls and pushes with git in its own terminal, "
                    + "which the user sees.")
    }
    /// In a folder of repositories, each one: a pull where it follows a remote branch, a push where there is
    /// something to send (a branch with nothing of its own isn't published). A failure in one doesn't stop the others,
    /// and all of them are said at the end.
    func handle(_ scm: SourceControl) throws -> Done {
        let folder = try scm.folder(id)
        guard let names = scm.repos(in: folder) else {
            try Git.remote(folder, op, remotes: scm.remotes)
            return Done()
        }
        try scm.remoteInEach(folder, names, op)
        return Done()
    }
}
extension GitFetchQuietly: Handled {
    /// Kelp's own clock fetches; an agent fetches with git in its terminal. A remote project's host is fetched over a
    /// connection already open: Kelp never dials a host by itself.
    func handle(_ scm: SourceControl) throws -> QuietFetch {
        let path = try scm.folder(worktreeId)
        guard scm.remotes.connected(path) else { return QuietFetch(ran: false) }
        // In a folder of repositories, each is fetched; the first trouble is the one said.
        let all = try scm.each(path) { try Git.fetchQuietly($0, remotes: scm.remotes) }.map(\.value)
        return all.first { $0.trouble != nil } ?? all[0]
    }
}
extension GitStash: Handled {
    func handle(_ scm: SourceControl) throws -> Done {
        let folder = try scm.folder(id)
        // A pop in each repository would bring back old stashes that have nothing to do with each other.
        guard scm.repos(in: folder) == nil else {
            throw RPCError.invalidParams("Stash in one repository at a time: this folder holds several.")
        }
        try Git.stash(folder, pop: pop == true, remotes: scm.remotes)
        return Done()
    }
}

extension GitWebURL: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> String {
        let last = end ?? start
        return try Git.webURL(
            path: path, lines: start.flatMap { s in last.map { min(s, $0)...max(s, $0) } }, remotes: scm.remotes)
    }
}

extension GitWebPages: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Pages? {
        let path = try scm.store.repoPath(worktreeId: worktreeId, repoId: repoId).1
        // With no origin there is nothing to link to.
        guard let origin = try? Git.origin(path, remotes: scm.remotes) else { return nil }
        return Git.webPages(remote: origin)
    }
}

extension FilesList: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try ProjectFiles.list(scm.folder(id), remotes: scm.remotes)
    }
}
extension FilesIgnored: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try ProjectFiles.ignored(scm.folder(id), folder: folder, remotes: scm.remotes)
    }
}
extension FilesSearch: Handled {
    static let agents = AgentAccess.reads
    func handle(_ scm: SourceControl) throws -> Result {
        try ProjectFiles.search(
            scm.folder(id), query: query, regex: regex == true, caseSensitive: `case` == true,
            wholeWord: word == true, replacing: replaces == true,
            remotes: scm.remotes)
    }
}

extension Methods {
    static let gitMethods: [any Answered.Type] = [
        GitStatus.self, GitBranches.self, GitLineStats.self, GitPush.self, GitDiff.self, GitLog.self, GitUnsynced.self,
        GitStage.self, GitUnstage.self, GitHunk.self, GitCommit.self, GitMerge.self, GitSwitch.self, GitGraph.self,
        GitCommitFiles.self, GitCommitDetails.self, GitCommitAct.self, GitLineOrigin.self, GitDiscard.self,
        GitDiscardHunk.self,
        GitUndoDiscard.self,
        GitRemoteOp.self, GitFetchQuietly.self, GitStash.self, GitWebURL.self, GitWebPages.self, FilesList.self,
        FilesIgnored.self,
        FilesSearch.self
    ]
}
