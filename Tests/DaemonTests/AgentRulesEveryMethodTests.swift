import Core
import Foundation
import Testing

@testable import Daemon

// The agent rules' table (`whoMayDoWhat`) for every method agents may call that the other tables don't name: taking
// one off `AgentRules.methods`, moving a read to what acts, or dropping a method's own rule fails its row.

/// An agent's session and the records the rows name: its own workspace, the user's terminal and a session the user
/// started from it, another workspace of the project.
private struct Rows {
    let w: World, wt: Worktree, mine: Session, theirs: Session, elsewhere: Worktree
}

private func rows() async throws -> Rows {
    let w = try await world()
    let wt = try await workspace(w, "feat/x")
    let term: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "command": "cat"]), as: Session.self)
    var mine = Session(worktreeId: wt.id, cwd: "/tmp", command: "claude", argv: ["claude"])
    mine.agent = "claude"
    var theirs = Session(worktreeId: wt.id, cwd: "/tmp", command: "cat", argv: ["cat"])
    theirs.origin = term.id
    let elsewhere = Worktree(repoId: w.repo.id, branch: "o", path: "/tmp/o")
    try w.d.sessions.store.save(mine)
    try w.d.sessions.store.save(theirs)
    try w.d.sessions.store.save(elsewhere)
    return Rows(w: w, wt: wt, mine: mine, theirs: theirs, elsewhere: elsewhere)
}

/// What names a session: an agent's own, never one the user started.
@Test func whoMayDoWhatWithASession() async throws {
    let r = try await rows()
    defer { r.w.d.stop() }
    let calls: [(String) -> any Answered] = [
        { SessionAttach(id: $0) }, { SessionStream(id: $0) }, { SessionDetach(id: $0) }, { SessionBusy(id: $0) },
        { SessionCommands(id: $0) },
        { SessionContext(id: $0) }, { SessionContextParts(id: $0) }, { SessionContextWindow(id: $0) },
        { SessionContinueAt(id: $0, at: nil) }, { SessionHandoff(id: $0) }, { SessionLastReply(id: $0) },
        { SessionMarkUnread(id: $0) }, { SessionRecap(id: $0) }, { SessionRestart(id: $0) },
        { SessionSubagentJournal(id: $0, subagent: "a") }, { SessionSubagentSteps(id: $0) }, { SessionTrail(id: $0) },
        { SessionTurn(id: $0) }, { SessionTurns(id: $0) }, { SessionWhy(id: $0) },
        { PaneReportAgent(paneId: $0, state: "idle") }
    ]
    let agent = Caller.session(r.mine.id)
    try expectRows(
        r.w.d,
        calls.flatMap { call in
            [(agent, call(r.mine.id), true, "its own session"), (agent, call(r.theirs.id), false, "not the user's")]
        })
}

/// What only reads looks at any workspace (a review of another branch); a session it names is still held to its own.
@Test func whoMayReadAWorkspace() async throws {
    let r = try await rows()
    defer { r.w.d.stop() }
    let calls: [(String) -> any Answered] = [
        { GitBranches(id: $0) }, { GitCommitDetails(id: $0, commit: "HEAD") },
        { GitCommitFiles(id: $0, commit: "HEAD") },
        { GitDiff(id: $0) }, { GitGraph(id: $0) }, { GitLineStats(id: $0) }, { GitLog(id: $0) },
        { GitUnsynced(id: $0) }, { GitAuthorAvatar(id: $0, email: "a@example.com") }, { FilesIgnored(id: $0) },
        { FilesList(id: $0) }, { FilesSearch(id: $0, query: "x") }, { CommentList(id: $0) }, { WorktreeDirty(id: $0) },
        { WorktreeUnmerged(id: $0) }, { CIFailures(worktreeId: $0) }, { CIFullLog(worktreeId: $0, job: nil) },
        { CIJobs(worktreeId: $0, run: nil) }, { CILog(worktreeId: $0, job: nil) }, { CIRunsList(worktreeId: $0) },
        { GitHubBranchPR(worktreeId: $0) }, { GitHubChecks(worktreeId: $0, pr: nil) },
        { GitHubFailedLog(worktreeId: $0, runId: nil) }, { GitHubForge(worktreeId: $0) },
        { GitHubIssues(worktreeId: $0) }, { GitHubPRs(worktreeId: $0) }, { GitHubProjects(worktreeId: $0) },
        { GitHubReviewComments(worktreeId: $0, pr: nil) }, { GitWebPages(worktreeId: $0) },
        { RunDetect(worktreeId: $0) }, { ScriptsList(worktreeId: $0) }, { SkillsBrowser(worktreeId: $0) },
        { AddonsList(worktreeId: $0) },
        { TmuxList(worktreeId: $0) }, { PortsList(worktreeId: $0) }, { SessionList(worktreeId: $0) },
        { RecipeRender(id: $0, name: "x") }
    ]
    let agent = Caller.session(r.mine.id)
    try expectRows(
        r.w.d,
        calls.map { (agent, $0(r.elsewhere.id), true, "a read looks at another's workspace") } + [
            (agent, WorktreeList(repoId: r.w.repo.id), true, "the project's workspaces"),
            (agent, RepoWorktreeSizes(id: r.w.repo.id), true, "and their sizes"),
            (agent, GitHubPRView(repoId: r.w.repo.id, pr: 1), true, "a pull request of the project"),
            (agent, GitHubIssueView(repoId: r.w.repo.id, issue: 1), true, "an issue of the project"),
            (agent, GitDiff(id: r.wt.id, session: r.theirs.id), false, "not a turn of a session the user started")
        ])
}

/// What reads nothing of a session or workspace (the IDE's state, accounts' status, a file, the usage): open to agents.
@Test func whoMayReadTheRest() async throws {
    let r = try await rows()
    defer { r.w.d.stop() }
    let calls: [any Answered] = [
        AgentsVersions(), BitbucketStatus(), ClientEvents(events: true), DaemonInfo(), ExtensionLibrary(),
        FilesFetch(path: r.wt.path + "/a"), FilesRead(path: r.wt.path + "/a"),
        GitHubProjectItems(owner: "o", number: nil), GitHubStatus(), GitLabStatus(), GitWebURL(path: r.wt.path),
        HistoryList(), HostStatsRead(host: "h"), JiraStatus(), LinearStatus(), Ping(),
        ProcessWhich(commands: ["git"]), RemoteListFolders(host: "h", path: "/"), RepoIcon(path: r.wt.path),
        RepoList(), RoutineList(), SessionUsage(), SettingsGet(), StateGet(), UIStateGet(), UsageAgents(),
        UsageGet(), VMDetailRead(name: "m"), VMList(), WatchStop(.git, r.wt.id)
    ]
    let agent = Caller.session(r.mine.id)
    // The trackers' contents are the user's: read with their keys, a query reaching the whole site.
    let trackers: [any Answered] = [
        JiraIssues(jql: "project = SECRET"), JiraTransitions(key: "K-1"), LinearIssues(), LinearStates(teamId: "t"),
        LinearTeams()
    ]
    try expectRows(
        r.w.d,
        calls.map { (agent, $0, true, "open to agents") }
            + trackers.map { (agent, $0, false, "not a tracker's issues, teams or transitions") })
}

/// What acts in the IDE or a machine: in its own workspace, and only what an agent's skills do.
@Test func whoMayActInTheIDEAndMachines() async throws {
    let r = try await rows()
    defer { r.w.d.stop() }
    let agent = Caller.session(r.mine.id)
    func routine(id: String = "", repo: String? = nil) -> Routine {
        Routine(id: id, name: "Nightly", repoId: repo ?? r.w.repo.id, agent: "claude", prompt: "x")
    }
    try expectRows(
        r.w.d,
        [
            (agent, PortsStop(worktreeId: r.wt.id, pid: nil), true, "a port's process in its own workspace"),
            (agent, PortsStop(worktreeId: r.elsewhere.id, pid: nil), false, "not in another's"),
            (agent, UIBrowser(action: .open, worktreeId: r.wt.id), true, "a page tab in its own workspace"),
            (agent, UIBrowser(action: .open, worktreeId: r.elsewhere.id), false, "not in another's"),
            (agent, UIBrowser(action: .open), false, "nor in the one on screen, which needn't be its own"),
            (
                agent, UIBrowserAsk(question: "Sign in", worktreeId: r.elsewhere.id), false,
                "nor hand another's page over"
            ),
            (agent, UICommand(id: "editor.goToLine"), true, "a command that shows something"),
            (agent, UICommand(id: "git.commit"), false, "not one of the user's"),
            (
                agent, UICommand(id: "scripts.openPage"), false,
                "nor ⇧⌘O, whose page tab is logged in as the user (its page can go on to any site)"
            ),
            (agent, ExtensionFetch(source: "https://example.com/x"), true, "an extension's files, to read"),
            (agent, VMConnect(name: "m", cwd: r.wt.path), true, "a machine to run in"),
            (agent, VMScreen(name: "m", args: ["screenshot"]), true, "its screen"),
            (agent, VMUI(name: "m"), true, "the controls on its screen"),
            (agent, VMType(name: "m", text: "hi"), true, "text typed into it"),
            (agent, VMType(name: "m"), false, "not its password"),
            (agent, VMControl(name: "m", action: .sleep), true, "a sleep: the next command wakes it"),
            (agent, VMControl(name: "m", action: .stop), false, "not a shutdown: other chats run in it"),
            (agent, VMCreate(name: "m"), true, "a machine, made once the user allows it on its row"),
            (agent, RoutineSet(routine: routine()), true, "a new routine in its project, added once the user allows"),
            (agent, RoutineSet(routine: routine(id: "r")), false, "not a change to one there"),
            (agent, RoutineSet(routine: routine(repo: UUID().uuidString)), false, "nor one in a project not its own"),
            (agent, RoutineDelete(id: "r"), false, "nor one deleted"),
            (agent, RoutineRun(id: "r"), false, "or run now")
        ])
}

/// Settings an agent may set, but the user's own (`SettingsSet.usersOnly`): how an agent calls the user, and every
/// project's language servers.
@Test func whoMaySetASetting() async throws {
    let r = try await rows()
    defer { r.w.d.stop() }
    let agent = Caller.session(r.mine.id)
    try expectRows(
        r.w.d,
        [
            (agent, SettingsSet(key: SettingKeys.editorFontSize.key, value: .double(13)), true, "how the editor looks"),
            (agent, SettingsSet(key: SettingKeys.onWaiting.key, value: .string("none")), false, "not how it calls"),
            (agent, SettingsSet(key: SettingKeys.onFinish.key, value: .string("none")), false, "when done"),
            (agent, SettingsSet(key: SettingKeys.onError.key, value: .string("none")), false, "or failed"),
            (agent, SettingsSet(key: SettingKeys.holdBanners.key, value: .bool(false)), false, "nor its banners"),
            (
                agent, SettingsSet(key: SettingKeys.languageServers.key, value: .object([:])), false,
                "nor every project's language servers, some of which run a program their settings name"
            )
        ])
}
