import Foundation
import Core

/// What an agent's program may reach, beside `Daemon.allow`, which asks these.
enum AgentRules {
    /// The methods an agent's program, or one kelpd runs (an extension's, a git hook), may call at all; each still has its
    /// own rules (`actsOn`, `inWorkspace`, …). What agents use (their skills, hooks and `kelp` commands) and what reads.
    /// Everything else is the user's (commits, pushes, PRs, CI, trackers, credentials, projects, routines, scripts, the
    /// daemon itself): a new method is closed to agents until it's put here. By type, so a renamed one stays named.
    static let methods: Set<String> = Set(types.map { $0.name })
    private static let types: [any RPCMethod.Type] = [
        // reading
        AgentsVersions.self, CIFailures.self, CIFullLog.self, CIJobs.self, CILog.self, CIRunsList.self,
        CommentList.self, DaemonInfo.self, Ping.self, ExtensionLibrary.self, FilesFetch.self, FilesIgnored.self,
        FilesList.self, FilesRead.self, FilesReadRemote.self, FilesSearch.self, GitAuthorAvatar.self, GitBranches.self,
        GitCommitDetails.self, GitCommitFiles.self, GitDiff.self, GitGraph.self, GitHunk.self, GitLineStats.self,
        GitLog.self, GitRemoteOp.self, GitStatus.self, GitUnsynced.self, GitWebPages.self, GitWebURL.self,
        GitHubBranchPR.self, GitHubChecks.self, GitHubFailedLog.self, GitHubForge.self, GitHubIssues.self,
        GitHubProjectItems.self, GitHubProjects.self, GitHubPRs.self, GitHubReviewComments.self, GitHubStatus.self,
        GitLabStatus.self, BitbucketStatus.self, JiraIssues.self, JiraStatus.self, JiraTransitions.self,
        LinearIssues.self, LinearStates.self, LinearStatus.self, LinearTeams.self, HistoryList.self,
        HostStatsRead.self, PortsList.self, ProcessWhich.self, RecipeRender.self, RemoteListFolders.self,
        RepoIcon.self, RepoList.self, RepoWorktreeSizes.self, RoutineList.self, RunDetect.self, ScriptsList.self,
        SessionBusy.self, SessionCommands.self, SessionContext.self, SessionContextParts.self,
        SessionContextWindow.self, SessionLastReply.self, SessionList.self, SessionRead.self,
        SessionSubagentJournal.self, SessionSubagentSteps.self, SessionTrail.self, SessionTurns.self,
        SessionUsage.self, SessionWhy.self, SettingsGet.self, SkillsBrowser.self, StateGet.self, TmuxList.self,
        UIStateGet.self, UsageAgents.self, UsageGet.self, VMDetailRead.self, VMList.self, WorktreeDirty.self,
        WorktreeList.self, WorktreeUnmerged.self, ClientEvents.self, WatchStart.self, WatchStop.self,
        // its own sessions and those it started (`actsOn`, named ids), its hooks and reports
        SessionAttach.self, SessionDetach.self, SessionResize.self, SessionCreate.self, SessionSend.self,
        SessionWrite.self, SessionKill.self, SessionRestart.self, SessionRename.self, SessionMarkRead.self,
        SessionMarkUnread.self, SessionRecap.self, SessionHandoff.self, SessionContinueAt.self, SessionTurn.self,
        SessionTurnUndo.self, SessionTurnRedo.self, SessionHook.self, SessionReport.self, SessionPermissionWait.self,
        PaneReportAgent.self, UsageReport.self, CommentAdd.self, CommentSend.self,
        // the IDE: what it shows anywhere (`ui.command`'s `forAgents`), what it opens or changes in its own workspaces
        // (`inWorkspace`), settings but the user's own (`SettingsSet.usersOnly`), and what its skills do
        UIOpen.self, UICommand.self, UIBrowser.self, PortsStop.self, SettingsSet.self, ExtensionFetch.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeNote.self, WorktreeArchive.self, WorktreeRemove.self,
        VMConnect.self, VMScreen.self, VMType.self, VMControl.self
    ]
}

extension Sessions {
    /// The sessions a call names, in any field (an `id`, a `session`, a `parent`, a list of them, a struct's or an
    /// enum's in turn): what an agent's call may reach is decided by what it names, not by each method remembering to
    /// say. Free-form JSON (`JSONValue`: a setting's value, a command's args) and bytes name none.
    func named(by m: Any) throws -> [String] {
        func strings(_ v: Any, depth: Int) throws -> [String] {
            if let s = v as? String { return [s] }
            guard !(v is JSONValue), !(v is Data) else { return [] }
            let parts = Mirror(reflecting: v).children
            // Deeper than any method's params go: refused, not taken for naming nobody.
            guard depth < 6 || parts.isEmpty else { throw RPCError.invalidParams("Kelp can't tell which sessions this call names.") }
            return try parts.flatMap { try strings($0.value, depth: depth + 1) }
        }
        return try strings(m, depth: 0).filter { UUID(uuidString: $0) != nil }.filter { try store.session($0) != nil }
    }

    /// Whether `w` is the workspace of `own` or of one that started it, one they made, or one a session it started works
    /// in (which it could start there only for one of those): an agent works there only.
    func works(_ own: String, in w: String) throws -> Bool {
        let line = try lineage(own)
        if line.contains(where: { $0.worktreeId == w }) { return true }
        if let maker = try store.worktree(w)?.madeBy, line.contains(where: { $0.id == maker || Caller.typed + $0.id == maker }) { return true }
        return try store.sessions().contains { s in try s.worktreeId == w && lineage(s.id).contains { $0.id == own } }
    }

    /// The sessions removing `e` ends: those of the workspace, or of every workspace of the project.
    func ending(_ e: Ending) throws -> [String] {
        let ids: Set<String> = switch e {
        case .workspace(let w): [w]
        case .project(let r): Set(try store.worktrees(repo: r).map(\.id))
        }
        return try store.sessions().filter { ids.contains($0.worktreeId ?? "") }.map(\.id)
    }
}
