import Core
import Foundation

/// What an agent's program may reach, beside `Daemon.allow`, which asks these.
enum AgentRules {
    /// The methods an agent's program, or one kelpd runs (an extension's, a git hook), may call at all; each still has its
    /// own rules (`actsOn`, `inWorkspace`, …). What agents use (their skills, hooks and `kelp` commands) and what reads.
    /// Everything else is the user's (commits, pushes, PRs, CI, trackers, credentials, projects, routines, scripts, the
    /// daemon itself): a new method is closed to agents until it's put here. By type, so a renamed one stays named.
    static let methods: Set<String> = Set((reading + acting).map { $0.name })
    /// What only reads: a workspace it names may be any (a review of another branch, a status); what acts is held to the
    /// agent's own workspaces, every one it names, whatever the field (`Store.workspaces(namedBy:)`).
    static let reads: Set<String> = Set(reading.map { $0.name })
    private static let reading: [any RPCMethod.Type] = [
        AgentsVersions.self, CIFailures.self, CIFullLog.self, CIJobs.self, CILog.self, CIRunsList.self,
        CommentList.self, DaemonInfo.self, Ping.self, ExtensionLibrary.self, FilesFetch.self, FilesIgnored.self,
        FilesList.self, FilesRead.self, FilesReadRemote.self, FilesSearch.self, GitAuthorAvatar.self, GitBranches.self,
        GitCommitDetails.self, GitCommitFiles.self, GitDiff.self, GitGraph.self, GitLineStats.self,
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
        DatabaseList.self, DatabaseSchemaRead.self
    ]
    private static let acting: [any RPCMethod.Type] = [
        // its own sessions and those it started (`actsOn`, named ids), its hooks and reports
        SessionAttach.self, SessionDetach.self, SessionResize.self, SessionCreate.self, SessionSend.self,
        SessionWrite.self, SessionKill.self, SessionRestart.self, SessionRename.self, SessionMarkRead.self,
        SessionMarkUnread.self, SessionRecap.self, SessionHandoff.self, SessionContinueAt.self, SessionTurn.self,
        SessionHook.self, SessionReport.self, SessionPermissionWait.self,
        PaneReportAgent.self, UsageReport.self, CommentAdd.self, CommentSend.self,
        // staging or unstaging a hunk writes the index: in its own workspaces only
        GitHunk.self,
        // the IDE: what it shows anywhere (`ui.command`'s `forAgents`), what it opens or changes in its own workspaces
        // (`inWorkspace`), settings but the user's own (`SettingsSet.usersOnly`), and what its skills do
        UIOpen.self, UICommand.self, UIBrowser.self, PortsStop.self, SettingsSet.self, ExtensionFetch.self,
        WorkspaceCreate.self, WorktreeCreate.self, WorktreeNote.self, WorktreeArchive.self, WorktreeRemove.self,
        VMConnect.self, VMScreen.self, VMType.self, VMControl.self,
        // a database's statement: read-only, or a change as the database's `agentAccess` says (`Databases.query`)
        DatabaseQuery.self
    ]
}

/// What the fence reads of a call (`Daemon.allow`): the sessions and workspaces it names, where an agent works, what a
/// removal ends. From the records, as `lineage` is.
extension Store {
    /// The sessions a call names, in any field (an `id`, a `session`, a `parent`, a list of them, a struct's or an
    /// enum's in turn): what an agent's call may reach is decided by what it names, not by each method remembering to
    /// say. Free-form JSON (`JSONValue`: a setting's value, a command's args) and bytes name none.
    func named(by params: Any) throws -> [String] {
        return try ids(params).filter { try session($0) != nil }
    }

    /// The workspaces a call names, in any field, as `named(by:)` finds sessions.
    func workspaces(namedBy params: Any) throws -> [String] { try ids(params).filter { try worktree($0) != nil } }

    /// Every id-shaped string in a call's params, at any depth (`named(by:)`'s walk).
    private func ids(_ params: Any) throws -> [String] {
        func strings(_ value: Any, depth: Int) throws -> [String] {
            if let string = value as? String { return [string] }
            guard !(value is JSONValue), !(value is Data) else { return [] }
            let parts = Mirror(reflecting: value).children
            // Deeper than any method's params go: refused, not taken for naming nobody.
            guard depth < 6 || parts.isEmpty else {
                throw RPCError.refused("Kelp can't tell which sessions this call names.")
            }
            return try parts.flatMap { try strings($0.value, depth: depth + 1) }
        }
        return try strings(params, depth: 0).filter { UUID(uuidString: $0) != nil }
    }

    /// Whether `workspace` is the workspace of `own` or of one that started it, one they made, or one a session it
    /// started works in (which it could start there only for one of those): an agent works there only.
    /// `typed`: an agent typed into `own`, the user's terminal: its workspace (it runs there), and the ones it made or
    /// started a session in, not those the user made or worked in from that terminal.
    func works(_ own: String, in workspace: String, typed: Bool = false) throws -> Bool {
        let line = try lineage(own)
        if line.contains(where: { $0.worktreeId == workspace }) { return true }
        let maker = try worktree(workspace)?.madeBy
        if typed {
            if Caller.started(maker, byAgentTypedInto: own) { return true }
        } else if let makerSession = Caller.session(of: maker), line.contains(where: { $0.id == makerSession }) {
            return true
        }
        return try sessions().contains { session in
            try session.worktreeId == workspace
                && lineage(session.id).contains {
                    typed ? Caller.started($0.origin, byAgentTypedInto: own) : $0.id == own
                }
        }
    }

    /// The sessions removing `target` ends: those of the workspace, or of every workspace of the project.
    func ending(_ target: Ending) throws -> [String] {
        let ids: Set<String> =
            switch target {
            case .workspace(let workspace): [workspace]
            case .project(let repo): Set(try worktrees(repo: repo).map(\.id))
            }
        return try sessions().filter { ids.contains($0.worktreeId ?? "") }.map(\.id)
    }
}
