import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The groups that closed by themselves: one with no tab and no agent stays a while (Settings › Appearance › Close
/// empty groups) after it was last on screen or lost its last tab, then goes.
extension WorkspaceActions {
    static let emptyKey = "workbench.emptySince"

    /// How long a group with nothing in it stays (Settings › Appearance › Close empty groups), or nil for Never.
    var emptyFor: TimeInterval? {
        switch app.settings[SettingKeys.closeEmptyGroups] {
        case "never": nil
        case "hour": 3600
        case "week": 7 * 86400
        default: 86400
        }
    }

    /// When each empty group was last on screen or lost its last tab, by group id.
    var emptySince: [String: Double] {
        guard case .object(let all)? = app.uiState[Self.emptyKey] else { return [:] }
        return all.compactMapValues(\.number)
    }

    /// Called when the screen left a group. A group with nothing open stays as it was set up, for a while.
    func left(_ id: String) {
        if app.workbench.layouts[id].allTabs.isEmpty { emptied(id) }
        closeIdle()
    }

    /// Called when a group's last tab closed or its last chat moved out: the time it may stay empty starts now.
    func emptied(_ id: String, now: Date = Date()) {
        var since = emptySince.filter { id in app.worktree(id.key) != nil }
        since[id] = now.timeIntervalSince1970
        app.uiState[Self.emptyKey] = .object(since.mapValues(JSONValue.double))
    }

    /// When an empty group closes by itself, or nil when it doesn't: it has a tab or an agent, it's on screen, it's the
    /// branch of a chat still open (whose agent works in that folder from another screen), or it's the project's own
    /// screen, or its branch holds work of its own as far as the list knows. Until the saved tabs are read, every group
    /// looks empty, so nothing closes then either.
    func closesAt(_ group: Worktree) -> Date? {
        guard let emptyFor, app.connected, app.uiState.loaded, !group.archived, !app.workbench.isOnScreen(group.id),
            app.workbench.layouts[group.id].allTabs.isEmpty,
            !app.sessions.contains(where: {
                $0.status != .exited && ($0.worktreeId == group.id || $0.id == SidebarTree.maker(group))
            }),
            let repo = app.repo(group.repoId), group.id != mainWorkspace(of: repo, among: app.workspaces(of: repo))?.id,
            group.path == repo.path || app.gitState.ownWork(group.id).map({ $0.commits + $0.files == 0 }) ?? true
        else { return nil }
        return (emptySince[group.id].map(Date.init(timeIntervalSince1970:)) ?? group.createdAt) + emptyFor
    }

    /// Closes the groups whose time ran out (`closesAt`). One on a branch with work of its own stays, since nothing of
    /// it may go unasked. On a visible list the row's sand runs out first (`Workbench.timeUp`), then the row goes.
    func closeIdle(now: Date = Date()) {
        for group in app.worktrees where closesAt(group).map({ $0 <= now }) == true {
            guard let repo = app.repo(group.repoId), WorkspaceActions.closing.insert(group.id).inserted,
                let next = WorkspaceClosing.afterLastTab(of: group, rows: app.workspaces(of: repo), repos: app.repos)
            else { continue }
            // Throws only when cancelled, and then the group stays.
            Task { () async throws in
                defer {
                    WorkspaceActions.closing.remove(group.id)
                    app.workbench.timeUp.remove(group.id)
                }
                if group.path != repo.path {
                    guard let work = await work(on: group.id), !work.isAny else { return }
                }
                if !Motion.reduced, app.workbench.mainWindow?.isVisible == true {
                    app.workbench.timeUp.insert(group.id)
                    try await Task.sleep(for: .seconds(Motion.fold * 2))
                }
                guard closesAt(group) != nil, await app.workbench.keepClosedTabs(of: group, on: next) else { return }
                _ = await app.quiet(WorktreeRemove(id: group.id))
            }
        }
    }
}

/// The groups `closeIdle` is closing now, so a second call meanwhile leaves them alone.
@MainActor private extension WorkspaceActions {
    static var closing: Set<String> = []
}
