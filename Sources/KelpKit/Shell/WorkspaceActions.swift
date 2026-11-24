import AppKit
import Core
import DesignKit
import WorkbenchKit

@MainActor
package struct WorkspaceActions {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    /// Reveals the focused tab's file or else the workspace's folder (Xcode's "Show in Finder" works on the selection).
    func revealCurrent() {
        // Nothing of a remote project is in the Finder (its folder here holds only its marker).
        let path = app.workbench.editor?.focusedContent?.fileURL?.path ?? app.worktree(app.workbench.workspaceId)?.path
        guard let path, Self.onHost(path) == nil else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// What exists only in a branch's folder. None of it may go without the user being asked.
    struct Work {
        var dirty: Bool, commits: Int
        var isAny: Bool { dirty || commits > 0 }
        var words: [String] {
            (dirty ? [String(localized: "It has uncommitted changes that will be lost.")] : [])
                + (commits > 0
                    ? [
                        String(
                            localized:
                                "\(commits) commits on this branch aren’t on any other branch or remote and will be lost."
                        )
                    ] : [])
        }
    }

    /// The work on a branch's folder, or nil when it can't be told (for example, the folder is gone).
    private func work(on id: String) async -> Work? {
        guard let dirty = await app.quiet(WorktreeDirty(id: id)),
            let commits = await app.quiet(WorktreeUnmerged(id: id))
        else {
            return nil
        }
        return Work(dirty: dirty, commits: commits)
    }

    func delete(_ worktree: Worktree) {
        Task {
            guard let (alert, work) = await deleteQuestion(worktree), await runSheet(alert) == .alertFirstButtonReturn
            else { return }
            await discard(worktree, work)
        }
    }

    /// The question to ask before deleting. It is nil when what would be lost can't be told, so the failed call's
    /// banner says why, instead of a question that reads as if nothing would be lost.
    func deleteQuestion(_ worktree: Worktree) async -> (NSAlert, Work)? {
        guard let dirty = await app.call(WorktreeDirty(id: worktree.id)),
            let commits = await app.call(WorktreeUnmerged(id: worktree.id))
        else { return nil }
        let work = Work(dirty: dirty, commits: commits)
        // The workspace's own copies of the project's databases that aren't files in its folder are dropped with it
        let copies = (await app.quiet(DatabaseList(worktreeId: worktree.id)) ?? [])
            .filter { $0.copy != nil && !$0.engine.isFile }.map(\.name).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(worktree.displayName)” and its branch?")
        alert.informativeText =
            (work.isAny
                ? work.words.joined(separator: " ")
                : String(localized: "The checkout and branch \(worktree.branch) are removed. Running agents stop."))
            + app.sessions.childrenWords(of: app.sessions.filter { $0.worktreeId == worktree.id }.map(\.id))
            + (copies.isEmpty ? "" : " " + String(localized: "Its database copy \(copies) goes too."))
        alert.addButton(
            withTitle: work.isAny
                ? String(localized: "Delete and Lose Changes") : String(localized: "Delete Folder and Branch")
        )
        .hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = work.isAny ? .critical : .warning
        return (alert, work)
    }

    private func discard(_ worktree: Worktree, _ work: Work) async {
        guard await UnsavedChanges.confirm(closing: [worktree.id], in: app) else { return }
        stepAway(from: worktree)
        await app.call(WorktreeRemove(id: worktree.id, force: work.dirty, dropCommits: work.commits > 0))
    }

    /// Whether Remove Clean Worktrees… is offered: not on another machine, where the worktrees aren't looked at.
    static func cleansWorktrees(_ repo: Repo) -> Bool { RemoteHost.of(repo.path) == nil }

    /// Removes the project's other git worktrees with nothing uncommitted (agents leave them in `.claude/worktrees`),
    /// after one question. Git itself keeps any that changed meanwhile, and Kelp's own workspaces aren't among them.
    func removeCleanWorktrees(_ repo: Repo) {
        Task {
            guard let all = await app.call(RepoWorktreeSizes(id: repo.id)) else { return }
            let clean = all.filter(\.removable), alert = NSAlert()
            guard !clean.isEmpty else {
                // Nothing to remove is a result, so a banner says it: a sheet would ask a question with one answer.
                let why =
                    all.isEmpty
                    ? String(localized: "The project has no other git worktrees.")
                    : String(
                        localized:
                            "Each of its \(all.count) worktrees has uncommitted changes, is locked or is in use in Kelp."
                    )
                return Banner.show(String(localized: "No clean worktrees in “\(repo.name)”") + ". " + why)
            }
            let size = WorktreeSizes.size(clean.reduce(0) { $0 + $1.bytes })
            alert.messageText =
                clean.count == 1
                ? String(
                    localized:
                        "Remove the clean worktree “\(WorktreeSizes.name(clean[0].path, root: repo.path))” (\(size))?")
                : String(localized: "Remove \(clean.count) clean worktrees (\(size))?")
            let names = clean.prefix(10).map {
                "\(WorktreeSizes.name($0.path, root: repo.path))  \(WorktreeSizes.size($0.bytes))"
            }
            alert.informativeText =
                (clean.count > 1 ? names.joined(separator: "\n") + (clean.count > 10 ? "\n…" : "") + "\n\n" : "")
                + String(
                    localized: """
                        Nothing uncommitted is lost: git removes only clean worktrees. A branch goes too if its commits are on another branch. \
                        Ignored files (builds, copied .env) go with the folder.
                        """)
            alert.addButton(
                withTitle: clean.count == 1
                    ? String(localized: "Remove Worktree") : String(localized: "Remove \(clean.count) Worktrees")
            )
            .hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn,
                let res = await app.call(RepoRemoveWorktrees(id: repo.id, paths: clean.map(\.path)))
            else { return }
            let freed = WorktreeSizes.size(clean.filter { res.removed.contains($0.path) }.reduce(0) { $0 + $1.bytes })
            if let why = res.kept.values.first {
                Banner.show(
                    String(localized: "Removed \(res.removed.count), kept \(res.kept.count): \(why)"), style: .error)
            } else {
                Banner.show(String(localized: "Removed \(res.removed.count) worktrees, \(freed) freed"))
            }
        }
    }

    /// Closes a group, ending its agents (asked first when any run) and leaving the project's files. A group on a
    /// branch goes with its folder and branch, asking first if they hold the only copy of something. A project's own
    /// screen stays.
    func close(_ worktree: Worktree) {
        guard let repo = app.repo(worktree.repoId),
            worktree.id != mainWorkspace(of: repo, among: app.workspaces(of: repo))?.id
        else {
            NSSound.beep()
            return
        }
        let open = app.sessions.filter { $0.worktreeId == worktree.id && $0.status != .exited }
        let running = open.filter { $0.status != .paused }, paused = open.count - running.count
        Task {
            if worktree.path != repo.path, let work = await work(on: worktree.id), work.isAny {
                await closeKeeping(worktree, work)
                return
            }
            if !open.isEmpty {
                let detail =
                    pausedGo(paused)
                    + (running.isEmpty
                        ? String(localized: "Files in the project are not touched.")
                        : running.count == 1
                            ? String(localized: "1 running agent stops. Files in the project are not touched.")
                            : String(
                                localized: "\(running.count) running agents stop. Files in the project are not touched."
                            ))
                let action =
                    running.isEmpty
                    ? String(localized: "Close")
                    : running.count == 1
                        ? String(localized: "Stop Agent and Close")
                        : String(localized: "Stop \(running.count) Agents and Close")
                guard
                    await confirm(
                        String(localized: "Close “\(worktree.displayName)”?"), detail: detail, action: action,
                        destructive: true)
                else { return }
            }
            guard await UnsavedChanges.confirm(closing: [worktree.id], in: app) else { return }
            stepAway(from: worktree)
            // If the removal is refused (an agent wrote something at the last moment), go back to what's still there.
            if await app.call(WorktreeRemove(id: worktree.id)) == nil { app.workbench.show(workspace: worktree.id) }
        }
    }

    /// The warning that closing takes a paused agent's tab and its history too, so it can't be opened from Kelp again.
    private func pausedGo(_ count: Int) -> String {
        count == 0
            ? ""
            : (count == 1
                ? String(localized: "1 paused agent closes for good. ")
                : String(localized: "\(count) paused agents close for good. "))
    }

    /// Closes a group whose branch has work of its own, keeping the branch unless the user says otherwise, because that
    /// work can't be got back.
    private func closeKeeping(_ worktree: Worktree, _ work: Work) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(worktree.displayName)” has work that’s nowhere else")
        alert.informativeText =
            (work.words + [
                String(localized: "Archive keeps it, agents paused, until Window › Archived Groups brings it back.")
            ])
            .joined(separator: " ")
        alert.addButton(withTitle: String(localized: "Archive"))
        alert.addButton(withTitle: String(localized: "Delete and Lose Changes")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        switch await runSheet(alert) {
        case .alertFirstButtonReturn: archive(worktree)
        case .alertSecondButtonReturn: await discard(worktree, work)
        default: break
        }
    }

    /// Lets the user pick the project's folder again after it was moved or renamed. Its workspaces follow.
    func relocate(_ repo: Repo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Where is “\(repo.name)” now?")
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = URL(fileURLWithPath: (repo.path as NSString).deletingLastPathComponent)
        Task {
            guard await runSheet(panel) == .OK, let url = panel.url else { return }
            await app.call(RepoRelocate(id: repo.id, path: url.path))
        }
    }

    /// Moves chats into a group of their own, named after the first chat. Their agents go on where they are.
    func newGroup(from chats: [String]) async {
        guard let first = chats.first.flatMap(app.session), let worktree = app.worktree(first.worktreeId),
            let made = await app.call(WorkspaceCreate(repoId: worktree.repoId))
        else { return }
        await app.call(WorktreeNote(id: made.id, note: app.catalog.displayName(first)))
        await move(chats, to: made.id)
    }

    func move(_ chats: [String], to id: String) async {
        let from = Set(chats.compactMap { app.session($0)?.worktreeId }).subtracting([id])
        for sid in chats { await app.call(SessionMove(id: sid, worktreeId: id)) }
        if let sid = chats.first { app.workbench.focus(session: sid) }
        for wid in from { app.workbench.editors?.chatsLeft(wid) }
    }

    /// How long a group with nothing in it stays: a day after it was last on screen or lost its last tab.
    static let emptyFor: TimeInterval = 24 * 3600
    static let emptyKey = "workbench.emptySince"

    /// When each empty group was last on screen or lost its last tab, by group id.
    var emptySince: [String: Double] {
        guard case .object(let all)? = app.uiState[Self.emptyKey] else { return [:] }
        return all.compactMapValues(\.number)
    }

    /// Called when the screen left a group. A group with nothing open stays as it was set up, for a day.
    func left(_ id: String) {
        if app.workbench.layouts[id].allTabs.isEmpty { emptied(id) }
        closeIdle()
    }

    /// Called when a group's last tab closed or its last chat moved out: the day it may stay empty starts now.
    func emptied(_ id: String, now: Date = Date()) {
        var since = emptySince.filter { id in app.worktree(id.key) != nil }
        since[id] = now.timeIntervalSince1970
        app.uiState[Self.emptyKey] = .object(since.mapValues(JSONValue.double))
    }

    /// Closes the groups that stayed empty for a day: no tab, no agent, not on screen, and not the branch of a chat
    /// still open (its agent works in that folder from another screen). One on a branch with work of its own stays, since nothing of it may go unasked. Until the saved tabs are read, every group looks empty.
    func closeIdle(now: Date = Date()) {
        guard app.connected, app.uiState.loaded else { return }
        let since = emptySince
        for group in app.worktrees where !group.archived && !app.workbench.isOnScreen(group.id) {
            let at = since[group.id].map(Date.init(timeIntervalSince1970:)) ?? group.createdAt
            guard now.timeIntervalSince(at) >= Self.emptyFor, app.workbench.layouts[group.id].allTabs.isEmpty,
                !app.sessions.contains(where: {
                    $0.status != .exited && ($0.worktreeId == group.id || $0.id == SidebarTree.maker(group))
                }),
                let repo = app.repo(group.repoId),
                let next = WorkspaceClosing.afterLastTab(of: group, rows: app.workspaces(of: repo), repos: app.repos)
            else { continue }
            Task {
                if group.path != repo.path {
                    guard let work = await work(on: group.id), !work.isAny else { return }
                }
                guard await app.workbench.keepClosedTabs(of: group, on: next) else { return }
                _ = await app.quiet(WorktreeRemove(id: group.id))
            }
        }
    }

    /// Closes several workspaces at once (sidebar multi-selection) with one question; each project keeps at least one.
    /// A workspace on its own branch goes if nothing is only there, and is archived otherwise, so nothing is lost.
    func close(_ ws: [Worktree]) {
        let model = app
        let plan = WorkspaceClosing(picked: ws, open: model.worktrees.filter { !$0.archived }, repos: model.repos),
            closing = plan.ids
        guard !closing.isEmpty else {
            NSSound.beep()
            return
        }
        let open = model.sessions.filter { session in
            session.worktreeId.map(closing.contains) == true && session.status != .exited
        }
        let running = open.filter { $0.status != .paused }
        let name = ws.first { $0.id == closing[0] }?.displayName ?? ""
        let question =
            closing.count == 1
            ? String(localized: "Close “\(name)”?") : String(localized: "Close \(closing.count) groups?")
        let detail =
            pausedGo(open.count - running.count)
            + (running.isEmpty
                ? ""
                : running.count == 1
                    ? String(localized: "1 running session stops. ")
                    : String(localized: "\(running.count) running sessions stop. "))
            + String(localized: "Files in the projects are not touched.")
            + (plan.keptSome ? " " + String(localized: "A project’s own chats stay.") : "")
        let action =
            running.isEmpty
            ? String(localized: "Close")
            : running.count == 1
                ? String(localized: "Stop 1 Session and Close")
                : String(localized: "Stop \(running.count) Sessions and Close")
        Task {
            guard await confirm(question, detail: detail, action: action, destructive: !open.isEmpty),
                await UnsavedChanges.confirm(closing: closing, in: app)
            else { return }
            if let id = app.workbench.workspaceId, closing.contains(id),
                let other = model.worktrees.first(where: { !$0.archived && !closing.contains($0.id) })
            {
                app.workbench.show(workspace: other.id)
            }
            for id in plan.remove { await model.call(WorktreeRemove(id: id)) }
            for id in plan.archive {
                if await work(on: id)?.isAny == false {
                    await model.call(WorktreeRemove(id: id))
                } else {
                    await model.call(WorktreeArchive(id: id))
                }
            }
        }
    }

    /// Takes a workspace out of the sidebar with nothing lost. Its agents pause and its tabs stay until it comes back
    /// (Window › Archived Workspaces).
    func archive(_ worktree: Worktree) {
        Task {
            guard await UnsavedChanges.confirm(closing: [worktree.id], in: app) else { return }
            stepAway(from: worktree)
            if await app.call(WorktreeArchive(id: worktree.id)) != nil {
                Banner.show(
                    String(localized: "“\(worktree.displayName)” archived. Window › Archived Groups brings it back."))
            }
        }
    }

    /// Shows another of the project's workspaces first when `worktree`, which is about to go, is the one on screen.
    private func stepAway(from worktree: Worktree) {
        guard app.workbench.workspaceId == worktree.id,
            let other = app.worktrees.first(where: {
                $0.repoId == worktree.repoId && $0.id != worktree.id && !$0.archived
            })
        else { return }
        app.workbench.show(workspace: other.id)
    }

    func unarchive(_ id: String) {
        Task {
            await app.call(WorktreeUnarchive(id: id))
            app.workbench.show(workspace: id)
        }
    }

    func removeProject(_ repo: Repo) {
        let branches = app.worktrees.filter { $0.repoId == repo.id && $0.path != repo.path }
        let detail = [
            String(localized: "Its agents stop, and its chats and routines leave Kelp for good."),
            branches.isEmpty
                ? nil : String(localized: "Folders of its branch groups stay on disk, and Kelp no longer lists them."),
            String(localized: "The repository on disk is not touched.")
        ].compactMap { $0 }.joined(separator: " ")
        Task {
            guard
                await confirm(
                    String(localized: "Remove “\(app.projectName(repo.id) ?? repo.name)” from Kelp?"), detail: detail,
                    action: String(localized: "Remove"), destructive: true),
                await UnsavedChanges.confirm(closing: app.worktrees.filter { $0.repoId == repo.id }.map(\.id), in: app)
            else { return }
            await app.call(RepoRemove(id: repo.id))
        }
    }
}
