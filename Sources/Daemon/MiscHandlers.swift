import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations
import ServiceManagement
import os

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
        return try workspaces.removeWorktrees(paths, of: repo)
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
        parts.setup = sessions.setup.claudeSetup(ls.snapshot).map { ClaudeContext.fit($0, to: parts.base) }
        return parts
    }
}

extension SessionSubagentSteps: Handled {
    func handle(_ sessions: Sessions) throws -> Result {
        guard let ls = sessions.existing(id), let parent = sessions.agentUsage.transcript(of: ls) else { return [:] }
        var last: Result = [:]
        for run in ls.snapshot.runningSubagents {
            guard let file = SubagentTranscript.file(parent: parent, id: run.id),
                let tail = Data(tail: 262_144, of: file),
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

extension Methods {
    /// The methods answered in this file, and a few whose domain has no list of its own.
    static let miscMethods: [any Handled.Type] = [
        DaemonInfo.self, DaemonBackgroundAllowed.self, StateGet.self, StateSet.self,
        SessionRename.self, SessionMove.self, SessionContextWindow.self, SessionContextParts.self,
        SessionSubagentSteps.self,
        SessionSubagentJournal.self, WorktreeNote.self, RepoWorktreeSizes.self, RepoRemoveWorktrees.self,
        RemoteListFolders.self, SessionReport.self, PaneReportAgent.self, ClientEvents.self, WatchStart.self,
        WatchStop.self,
        RoutineList.self, RoutineSet.self, RoutineDelete.self, RoutineRun.self
    ]
}
