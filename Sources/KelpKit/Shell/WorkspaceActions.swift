import AppKit
import Core
import DesignKit
import WorkbenchKit

@MainActor
package struct WorkspaceActions {
    let app: AppModel
    init(_ app: AppModel) { self.app = app }

    /// The file in the focused tab, else the workspace's folder (Xcode's "Show in Finder" works on the selection).
    func revealCurrent() {
        if let url = app.workbench.editor?.focusedContent?.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        guard let worktree = app.worktree(app.workbench.workspaceId) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
    }

    /// What exists only in a branch's folder: nothing about it may go without being asked.
    private struct Work {
        var dirty: Bool, commits: Int
        var isAny: Bool { dirty || commits > 0 }
        var words: [String] {
            (dirty ? [String(localized: "It has uncommitted changes that will be lost.")] : [])
                + (commits > 0
                    ? [
                        String(
                            localized:
                                "\(commits) commits on this branch aren't on any other branch or remote and will be lost."
                        )
                    ] : [])
        }
    }

    /// Nil: can't tell (its folder is gone, say).
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
            let work = Work(
                dirty: await app.call(WorktreeDirty(id: worktree.id)) ?? false,
                commits: await app.call(WorktreeUnmerged(id: worktree.id)) ?? 0)
            let alert = NSAlert()
            alert.messageText = String(localized: "Delete “\(worktree.displayName)” and its branch?")
            alert.informativeText =
                (work.isAny
                    ? work.words.joined(separator: " ")
                    : String(localized: "The checkout and branch \(worktree.branch) are removed. Running agents stop."))
                + app.sessions.childrenWords(of: app.sessions.filter { $0.worktreeId == worktree.id }.map(\.id))
            alert.addButton(
                withTitle: work.isAny
                    ? String(localized: "Delete and Lose Changes") : String(localized: "Delete Folder and Branch")
            )
            .hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.alertStyle = work.isAny ? .critical : .warning
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            await discard(worktree, work)
        }
    }

    private func discard(_ worktree: Worktree, _ work: Work) async {
        guard await UnsavedChanges.confirm(closing: [worktree.id], in: app) else { return }
        if app.workbench.workspaceId == worktree.id,
            let main = app.worktrees.first(where: { $0.repoId == worktree.repoId && $0.id != worktree.id })
        {
            app.workbench.show(workspace: main.id)
        }
        await app.call(WorktreeRemove(id: worktree.id, force: work.dirty, dropCommits: work.commits > 0))
    }

    /// The project's other git worktrees with nothing uncommitted (agents leave them in `.claude/worktrees`), after one
    /// question; git itself keeps any that changed meanwhile. Kelp's own workspaces aren't among them.
    func removeCleanWorktrees(_ repo: Repo) {
        Task {
            guard let all = await app.call(RepoWorktreeSizes(id: repo.id)) else { return }
            let clean = all.filter(\.removable), alert = NSAlert()
            guard !clean.isEmpty else {
                alert.messageText = String(localized: "No clean worktrees in “\(repo.name)”")
                alert.informativeText =
                    all.isEmpty
                    ? String(localized: "The project has no other git worktrees.")
                    : String(
                        localized:
                            "Each of its \(all.count) worktrees has uncommitted changes, is locked or is in use in Kelp."
                    )
                _ = await runSheet(alert)
                return
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

    /// A group: its agents end, the project's files stay. Asks only when agents are running there. One on a branch goes with
    /// its folder and branch, and first asks if they hold the only copy of something. A project's own screen stays.
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
            if app.workbench.workspaceId == worktree.id,
                let other = app.worktrees.first(where: { $0.repoId == worktree.repoId && $0.id != worktree.id })
            {
                app.workbench.show(workspace: other.id)
            }
            // Refused (an agent wrote something at the last moment): back to what's still there.
            if await app.call(WorktreeRemove(id: worktree.id)) == nil { app.workbench.show(workspace: worktree.id) }
        }
    }

    /// Closing takes a paused agent's tab and its history too: it can't be opened from Kelp again.
    private func pausedGo(_ count: Int) -> String {
        count == 0
            ? ""
            : (count == 1
                ? String(localized: "1 paused agent closes for good. ")
                : String(localized: "\(count) paused agents close for good. "))
    }

    /// A branch with work of its own: kept unless told otherwise, as it can't be got back.
    private func closeKeeping(_ worktree: Worktree, _ work: Work) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(worktree.displayName)” has work that's nowhere else")
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

    /// The project's folder was moved or renamed: pick it again; its workspaces follow.
    func relocate(_ repo: Repo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Where is “\(repo.name)” now?")
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = URL(fileURLWithPath: (repo.path as NSString).deletingLastPathComponent)
        let chosen = { (resp: NSApplication.ModalResponse) in
            guard resp == .OK, let url = panel.url else { return }
            Task { await app.call(RepoRelocate(id: repo.id, path: url.path)) }
        }
        if let host = NSApp.mainWindow {
            panel.beginSheetModal(for: host, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }

    /// Chats off to a group of their own, named after the first. Their agents go on where they are.
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

    /// The screen moved on from a group: one with nothing open lived only while it was on screen.
    func left(_ id: String) {
        if app.workbench.layouts[id].allTabs.isEmpty { closeEmpty(id, ended: nil) }
    }

    /// Its last tab was closed: its row goes too, with nothing to ask, unless it's the one on screen, which then offers
    /// what to open next and goes when the screen moves on (`left`). One on a branch with work of its own stays, and says
    /// so: nothing there is decided by closing a tab. `ended`: that tab's session, still on its way out.
    func closeEmpty(_ id: String, ended: String?) {
        guard app.workbench.workspaceId != id else { return }
        // Its children end with it, a moment later: they have no tab, and nothing would come back to close this.
        var ending = Set([ended].compactMap { $0 })
        while case let more = Set(app.sessions.filter { $0.parent.map(ending.contains) == true }.map(\.id)).subtracting(
            ending), !more.isEmpty
        {
            ending.formUnion(more)
        }
        guard let group = app.worktree(id), let repo = app.repo(group.repoId),
            !app.sessions.contains(where: { $0.worktreeId == id && !ending.contains($0.id) && $0.status != .exited }),
            let next = WorkspaceClosing.afterLastTab(of: group, rows: app.workspaces(of: repo), repos: app.repos)
        else { return }
        Task {
            if group.path != repo.path {
                guard let work = await work(on: id) else { return }
                if work.isAny {
                    Banner.show(
                        String(
                            localized:
                                "“\(group.displayName)” stays: its work is only on \(group.branch). ⇧⌘W closes it."
                        ))
                    return
                }
            }
            if app.workbench.workspaceId == id { app.workbench.show(workspace: next.id) }
            await app.workbench.keepClosedTabs(of: group, on: next)
            // The agent that just ended may have left something after all: then it stays, as above.
            if await app.call(WorktreeRemove(id: id)) == nil { app.workbench.show(workspace: id) }
        }
    }

    /// Several at once (sidebar multi-selection): one question; each project keeps at least one workspace.
    /// Workspaces close; one on its own branch goes if nothing is only there, else it's archived (nothing is lost).
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
            + (plan.keptSome ? " " + String(localized: "A project's own chats stay.") : "")
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

    /// Out of the sidebar, nothing lost: its agents pause and its tabs stay until it comes back (Window › Archived Workspaces).
    func archive(_ worktree: Worktree) {
        Task {
            guard await UnsavedChanges.confirm(closing: [worktree.id], in: app) else { return }
            if app.workbench.workspaceId == worktree.id,
                let other = app.worktrees.first(where: {
                    $0.repoId == worktree.repoId && $0.id != worktree.id && !$0.archived
                })
            {
                app.workbench.show(workspace: other.id)
            }
            if await app.call(WorktreeArchive(id: worktree.id)) != nil {
                Banner.show(
                    String(localized: "“\(worktree.displayName)” archived. Window › Archived Groups brings it back."))
            }
        }
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
