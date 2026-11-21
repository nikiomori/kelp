import Core
import Testing

@testable import Daemon

/// What an agent's program may call, as the handlers say it (`Answered.agents`), written out whole: a method opened to
/// agents, or moved from reading to acting, shows here in its diff, where it's looked at as the fence it changes.
@Test func theMethodsAgentsMayCallAreTheseAndNoOthers() {
    let reads: [any RPCMethod.Type] = [
        AddonsList.self, AgentsVersions.self, ArtifactCheck.self, BitbucketStatus.self, CIFailures.self,
        CIFullLog.self, CIJobs.self, CILog.self, CIRunsList.self, ClientEvents.self, CommentList.self,
        DaemonInfo.self, ExtensionLibrary.self, FilesFetch.self, FilesIgnored.self, FilesList.self,
        FilesRead.self, FilesSearch.self, GitAuthorAvatar.self, GitBranches.self, GitCommitDetails.self,
        GitCommitFiles.self, GitDiff.self, GitGraph.self, GitHubBranchPR.self, GitHubChecks.self,
        GitHubFailedLog.self, GitHubForge.self, GitHubIssueView.self, GitHubIssues.self, GitHubPRView.self,
        GitHubPRs.self, GitHubProjectItems.self, GitHubProjects.self, GitHubReviewComments.self,
        GitHubStatus.self, GitLabStatus.self, GitLineStats.self, GitLog.self, GitRemoteOp.self, GitStatus.self,
        GitUnsynced.self, GitWebPages.self, GitWebURL.self, HistoryList.self, HostStatsRead.self,
        JiraStatus.self, LinearStatus.self, Ping.self, PortsList.self, ProcessWhich.self, RecipeRender.self,
        RemoteListFolders.self, RepoIcon.self, RepoList.self, RepoWorktreeSizes.self, RoutineList.self,
        RunDetect.self, ScriptsList.self, SessionBusy.self, SessionCommands.self, SessionContext.self,
        SessionContextParts.self, SessionContextWindow.self, SessionLastReply.self, SessionList.self,
        SessionRead.self, SessionSubagentJournal.self, SessionSubagentSteps.self, SessionTrail.self,
        SessionTurns.self, SessionUsage.self, SessionWhy.self, SettingsGet.self, SkillsBrowser.self,
        StateGet.self, TmuxList.self, UIStateGet.self, UsageAgents.self, UsageGet.self, VMDetailRead.self,
        VMList.self, WatchStart.self, WatchStop.self, WorktreeDirty.self, WorktreeList.self,
        WorktreeUnmerged.self
    ]
    let acts: [any RPCMethod.Type] = [
        ArtifactAdd.self, ArtifactNew.self, ArtifactReply.self, CommentAdd.self, CommentSend.self, CommitPlanAdd.self,
        DatabaseList.self, DatabaseQuery.self, DatabaseSchemaRead.self, ExtensionFetch.self, GitHunk.self,
        PaneReportAgent.self, PortsStop.self, RoutineSet.self, SessionAttach.self, SessionContinueAt.self,
        SessionCreate.self, SessionDetach.self, SessionHandoff.self, SessionHook.self, SessionKill.self,
        SessionMarkRead.self, SessionMarkUnread.self, SessionPermissionWait.self, SessionRecap.self,
        SessionRename.self, SessionReport.self, SessionResize.self, SessionRestart.self, SessionSend.self,
        SessionStream.self, SessionTurn.self, SessionWrite.self, SettingsSet.self, UIBrowser.self,
        UIBrowserAsk.self, UICommand.self, UIOpen.self, VMConnect.self, VMControl.self, VMCreate.self,
        VMScreen.self, VMType.self, VMUI.self, WorkspaceCreate.self, WorktreeArchive.self, WorktreeCreate.self,
        WorktreeNote.self, WorktreeRemove.self
    ]
    #expect(AgentRules.reads == Set(reads.map { $0.name }))
    #expect(AgentRules.methods == Set((reads + acts).map { $0.name }))
}
