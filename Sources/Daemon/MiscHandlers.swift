import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations
import ServiceManagement
import os

extension GitDiscardHunk: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        let worktree = try workspaces.store.worktree(named: id)
        guard let diff = try Git.diff(worktree.path, source: .unstaged, file: file, remotes: workspaces.remotes).first,
            diff.hunks.indices.contains(hunk),
            diff.hunks[hunk].header == header, fingerprint.map({ $0 == diff.hunks[hunk].fingerprint }) ?? true
        else {
            throw RPCError.invalidParams("The file changed since it was shown; nothing was discarded.")
        }
        try workspaces.keepDiscard(.init(patch: diff.patch(hunk: hunk), hunk: true), folder: worktree.path, name: undo)   // first: see Git.discard
        try Git.discardHunk(worktree.path, diff: diff, hunk: hunk, remotes: workspaces.remotes)
        return Done()
    }
}

extension WorktreeNote: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard try workspaces.store.update(Worktree.self, id, { $0.note = note }) != nil else {
            throw RPCError.invalidParams("no worktree")
        }
        workspaces.notify(ChangedEvent.worktree)
        return Done()
    }
}

extension RepoWorktreeSizes: Handled {
    func handle(_ workspaces: Workspaces) throws -> [Item] {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        guard workspaces.remotes.of(repo.path) == nil else { return [] }   // their disk is on the host
        let ours = try Self.ours(workspaces.store, repo)
        return try Git.linkedWorktrees(repo.path, remotes: workspaces.remotes).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.map { worktree in
            Item(
                path: worktree.path, bytes: Self.du(worktree.path),
                removable: !worktree.locked && !ours.contains(Self.real(worktree.path))
                    && (try? Git.isDirty(worktree.path, remotes: workspaces.remotes)) == false
                    && Git.commitsOnNoBranch(worktree.path, remotes: workspaces.remotes) == 0)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Kelp's own worktree workspaces (from older versions): git prints real paths, the store keeps them as created.
    static func ours(_ store: Store, _ repo: Repo) throws -> Set<String> {
        Set(try store.worktrees(repo: repo.id).map { real($0.path) })
    }
    static func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// Blocks on disk as `du` counts them (16 GB of build products: about a second); unreadable files leave out only themselves.
    static func du(_ path: String) -> Int {
        let out = (try? Git.run(["-sk", path], cwd: path, executable: "/usr/bin/du", ok: [0, 1])) ?? ""
        return (Int(out.prefix { $0.isNumber }) ?? 0) * 1024
    }
}

extension RepoRemoveWorktrees: Handled {
    var notForAgents: String? { "Only the user clears a project's worktrees." }
    func handle(_ workspaces: Workspaces) throws -> Result {
        guard let repo = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let linked = try Git.linkedWorktrees(repo.path, remotes: workspaces.remotes),
            ours = try RepoWorktreeSizes.ours(workspaces.store, repo)
        var out = Result(removed: [], kept: [:])
        // A paused agent comes back where it last worked: its folder is as much in use as a running one's.
        let stored = try workspaces.store.sessions().filter { $0.status != .exited }.map(\.currentDir)
        let inUse = workspaces.sessions.live.all.map(\.snapshot.currentDir) + stored
        for path in paths {
            guard let worktree = linked.first(where: { $0.path == path }), !ours.contains(RepoWorktreeSizes.real(path))
            else {
                out.kept[path] = "Not one of the project's other worktrees."
                continue
            }
            // Nothing in it yet is what a worktree an agent just made looks like: its folder would go from under it.
            let real = RepoWorktreeSizes.real(path) + "/"
            if inUse.contains(where: { (RepoWorktreeSizes.real($0) + "/").hasPrefix(real) }) {
                out.kept[path] = "An agent works in it."
                continue
            }
            // git removes one whose commits are on no branch (a detached HEAD): they'd be left to `git gc`.
            if case let commits = Git.commitsOnNoBranch(path, remotes: workspaces.remotes), commits > 0 {
                out.kept[path] = "It has \(commits) commit\(commits == 1 ? "" : "s") on no branch (a detached HEAD)."
                continue
            }
            do {
                // Kept with changes, untracked files or a lock; else the folder goes to the Trash, ignored files (.env, a
                // local database) and all, which `git worktree remove` would delete for good. Its branch stays: below.
                try Git.removeWorktree(
                    repo: repo.path, path: path, branch: nil, force: false, remotes: workspaces.remotes)
                // -d: only if its commits are on another branch
                if let branch = worktree.branch, Git.isRevision(branch) {
                    _ = Log.store.attempt("deleting merged branch \(branch)") {
                        try Git.run(["branch", "-d", branch], cwd: repo.path, remotes: workspaces.remotes)
                    }
                }
                out.removed.append(path)
            } catch let error as GitError { out.kept[path] = error.message } catch {
                out.kept[path] = error.localizedDescription
            }
        }
        return out
    }
}

extension SessionReport: Handled {
    var reportsFor: String? { id }
    static var quick: Bool { true }   // `kelp report`: the agent waits for it
    func handle(_ sessions: Sessions) throws -> Done {
        guard ProgramStatus.states.contains(state) else {
            throw RPCError.invalidParams("state is one of idle, working, blocked, done, error, clear")
        }
        guard let ls = sessions.existing(id) else { return Done() }   // ended or paused: there's nothing to show it on
        let report = ProgramStatus.Report(
            state: state, kind: state == "blocked" ? kind : nil, msg: message,
            progress: state == "working" ? progress.map { min(100, max(0, $0)) } : nil)
        if ls.report(report) != nil { sessions.publish(ls) }
        return Done()
    }
}

/// herdr has no "done": idle after work is a finished turn (`StatusDetector.program`).
extension PaneReportAgent: Handled {
    var reportsFor: String? { paneId }
    static var quick: Bool { true }   // fx waits for the reply
    func handle(_ sessions: Sessions) throws -> Done {
        guard ["idle", "working", "blocked"].contains(state) else {
            throw RPCError.invalidParams("state is one of idle, working, blocked")
        }
        guard let ls = sessions.existing(paneId) else { return Done() }
        if ls.report(ProgramStatus.Report(state: state)) != nil { sessions.publish(ls) }
        return Done()
    }
}

extension SessionContextWindow: Handled {
    func handle(_ sessions: Sessions) throws -> Usage? {
        guard let transcript = sessions.existing(id).flatMap(sessions.agentUsage.transcript(of:)),
            let context = AgentUsage.contextUsage(transcript: transcript)
        else { return nil }
        return Usage(
            used: context.used, window: sessions.agentUsage.contextWindow(model: context.model, peak: context.peak),
            cacheUntil: context.cacheUntil)
    }
}

extension RoutineList: Handled {
    func handle(_ workspaces: Workspaces) throws -> RoutinesEvent { try workspaces.routines.list() }
}
extension RoutineSet: Handled {
    /// A routine starts agents later, from nobody's session: what an agent set up would run as the user's own.
    static let theUsers =
        "A routine is the user's to set up: in Kelp's window (Routines), or `kelp routine` in a terminal of theirs."
    var notForAgents: String? { Self.theUsers }
    func handle(_ workspaces: Workspaces) throws -> Routine { try workspaces.routines.set(routine) }
}
extension RoutineDelete: Handled {
    var notForAgents: String? { RoutineSet.theUsers }
    func handle(_ workspaces: Workspaces) throws -> Done {
        try workspaces.routines.delete(id)
        return Done()
    }
}
extension RoutineRun: Handled {
    func handle(_ workspaces: Workspaces) throws -> Routine.Run {
        try workspaces.routines.runNow(id, workspaces: workspaces)
    }
}

extension SessionContextParts: Handled {
    func handle(_ sessions: Sessions) throws -> Parts? {
        guard let ls = sessions.existing(id), let transcript = sessions.agentUsage.transcript(of: ls),
            let context = AgentUsage.contextUsage(transcript: transcript),
            var parts = ClaudeContext.parts(
                try Data(contentsOf: transcript, options: .mappedIfSafe), used: context.used)
        else { return nil }
        parts.setup = sessions.claudeSetup(ls.snapshot).map { ClaudeContext.fit($0, to: parts.base) }
        return parts
    }
}

extension SessionSubagentSteps: Handled {
    func handle(_ sessions: Sessions) throws -> Result {
        guard let ls = sessions.existing(id), let parent = sessions.agentUsage.transcript(of: ls) else { return [:] }
        var last: Result = [:]
        for run in ls.snapshot.runningSubagents {
            guard let file = SubagentTranscript.file(parent: parent, id: run.id),
                let tail = Data(tailOf: file, bytes: 262_144),
                let step = SubagentTranscript.lastStep(tail: tail),
                let touched = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            last[run.id] = Last(step: step, touched: touched)
        }
        return last
    }
}

extension SessionSubagentJournal: Handled {
    func handle(_ sessions: Sessions) throws -> Result {
        let usage = sessions.agentUsage
        guard
            let parent = try sessions.existing(id).flatMap(usage.transcript(of:))
                ?? sessions.store.session(id).flatMap(usage.transcript(of:)),
            let file = SubagentTranscript.file(parent: parent, id: subagent),
            FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return try SubagentTranscript.journal(file)
    }
}

extension Data {
    /// The file's last `bytes` (all of it when shorter); nil when it can't be opened.
    init?(tailOf url: URL, bytes: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        self = (try? handle.readToEnd()) ?? Data()
    }
}

extension Methods {
    /// The methods answered in this file, and a few whose domain has no list of its own.
    static let miscMethods: [any Handled.Type] = [
        DaemonInfo.self, DaemonBackgroundAllowed.self, StateGet.self, StateSet.self,
        SessionRename.self, SessionMove.self, SessionContextWindow.self, SessionContextParts.self,
        SessionSubagentSteps.self,
        SessionSubagentJournal.self, WorktreeNote.self, RepoWorktreeSizes.self, RepoRemoveWorktrees.self,
        GitDiscardHunk.self,
        RemoteListFolders.self, SessionReport.self, PaneReportAgent.self, ClientEvents.self, WatchStart.self,
        WatchStop.self,
        RoutineList.self, RoutineSet.self, RoutineDelete.self, RoutineRun.self
    ]
}
