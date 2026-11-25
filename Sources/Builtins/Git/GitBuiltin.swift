import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    package static let git = Builtin(
        "kelp.git", "Source Control", "Changes and staging, commits, branches, the history graph and diffs, with Git.",
        icon: "arrow.triangle.branch"
    ) { app in
        let changed = ChangedFiles(app: app)
        let panel: LivePanel = app.part { LivePanel() }   // the one the panel on screen was built with, at every reload
        _ = BackgroundFetch.of(app)   // fetches while Kelp is in front, from the start
        return Contributions(
            panels: [
                PanelSpec(
                    id: "git.changes", title: "Source Control", icon: "arrow.triangle.branch", extensionId: "kelp.git",
                    role: .changes,
                    badge: { changed.count > 0 ? PanelBadge(count: changed.count) : nil }
                ) {
                    let controller = SourceControlController(app: app)
                    panel.controller = controller
                    return controller
                }
            ],
            editors: [
                EditorSpec(
                    id: "git.review", title: "Review Changes", icon: "plus.forwardslash.minus",
                    uri: { ctx in ctx.workspace.map { DiffTab.uri($0.id) } })
            ],
            commands: [
                CommandSpec(id: "git.review", title: "Git: Review Changes", key: "shift+cmd+r") { _ in
                    if let workspace = app.workbench.workspaceId { app.workbench.open(DiffTab.uri(workspace)) }
                },
                CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request…") { _ in
                    if let workspace = app.workbench.workspaceId { PRActions(app).create(worktree: workspace) }
                },
                // The panel's quick actions, with their keys. They go through the panel when it's built (for its
                // message and its progress).
                CommandSpec(id: "git.commit", title: "Git: Commit", key: "opt+cmd+c") { _ in
                    if let controller = panel.controller, controller.worktreeId == app.workbench.workspaceId {
                        controller.commitPressed()
                    } else if let workspace = app.workbench.workspaceId {
                        app.workbench.open(CommitMessageTab.uri(workspace))
                    }
                },
                CommandSpec(id: "git.commitWithAgent", title: "Git: Write Commit with Agent") { _ in
                    // The agent's words show in the panel's Message field, so when the panel isn't on screen it is
                    // shown first.
                    guard let controller = panel.controller, controller.worktreeId == app.workbench.workspaceId
                    else { return app.workbench.showPanel("git.changes") }
                    controller.askLastAgent()
                },
                CommandSpec(id: "git.pull", title: "Git: Pull", key: "opt+cmd+x") { _ in
                    remote(app, panel, .pull, String(localized: "Pulled")) { $0.pullPressed() }
                },
                CommandSpec(id: "git.push", title: "Git: Push", key: "opt+cmd+p") { _ in
                    remote(app, panel, .push, String(localized: "Pushed")) { $0.pushPressed() }
                },
                CommandSpec(id: "git.fetch", title: "Git: Fetch", key: "opt+cmd+f") { _ in
                    remote(app, panel, .fetch, String(localized: "Fetched")) { $0.fetchPressed() }
                },
                // The panel's ⋯ menu's stash actions.
                CommandSpec(id: "git.stash", title: "Git: Stash Changes") { _ in stash(app, panel, pop: false) },
                CommandSpec(id: "git.popStash", title: "Git: Pop Stash") { _ in stash(app, panel, pop: true) },
                // The diff's steps between its changes and its comments, as the arrows on its bar step.
                step(app, "git.nextChange", "Git: Next Change", "opt+down", 1),
                step(app, "git.previousChange", "Git: Previous Change", "opt+up", -1),
                step(app, "git.nextComment", "Git: Next Comment", "shift+opt+down", 1),
                step(app, "git.previousComment", "Git: Previous Comment", "shift+opt+up", -1),
                // What the branch chip's menu copies, for the keyboard.
                CommandSpec(
                    id: "git.copyBranchName", title: "Git: Copy Branch Name", enabled: { branchName(app) != nil }
                ) { _ in
                    if let name = branchName(app) { copyText(name) }
                }
            ] + commitCommands(panel),
            settings: [
                SettingsSection(
                    id: "git", title: "Source Control", icon: "arrow.triangle.branch",
                    specs: [
                        s(
                            SettingKeys.branchPrefix, "Branch prefix", .string, "Added to branches Kelp names.",
                            placeholder: "you/"),
                        s(
                            SettingKeys.worktreesFolder, "Folder for worktrees", .string,
                            "Empty: inside Kelp’s own folder.",
                            help:
                                "Each project’s branches go in a folder named after it there, e.g. ~/worktrees. Empty: inside Kelp’s own folder.",
                            placeholder: "~/worktrees"),
                        // BackgroundFetch keeps it.
                        s(
                            SettingKeys.fetchInBackground, "Fetch in the background", .boolean,
                            "Every 5 minutes while Kelp is in front.",
                            help:
                                "Every 5 minutes while Kelp is in front, and at once when you come back to it, for the projects in the sidebar. Never asks for a password."
                        ),
                        // Where a branch's CI shows. RowMarks keeps it, and gh / glab are asked only for what one of
                        // these places shows.
                        s(
                            SettingKeys.ciBranchChip, "CI on the branch chip", .enum,
                            "A ring while it runs, a red dot when it fails.",
                            help:
                                "A ring while it runs, a red dot when it fails, an orange ring while a deploy waits for approval, a grey check for a minute after it passes.",
                            options: ["icon", "end", "off"],
                            labels: [
                                "icon": String(localized: "In Place of the Branch Icon"),
                                "end": String(localized: "After the Counts"), "off": String(localized: "Off")
                            ], group: "CI"),
                        s(
                            SettingKeys.ciSidebar, "CI beside folders", .boolean,
                            "In the sidebar and the ⌃Tab switcher.",
                            help:
                                "In the sidebar and the ⌃Tab switcher; a grey check until you open the folder. Off also stops checking CI for the others.",
                            group: "CI"),
                        s(
                            SettingKeys.ciPopover, "CI in the branch popover", .boolean,
                            "The newest run of each workflow; a click opens CI Runs.", group: "CI")
                    ], order: 80)
            ],
            tabs: [
                TabProvider(
                    schemes: ["diff"], make: { DiffTab(uri: $0, app: app) },
                    placeholder: { _ in (String(localized: "Changes"), .symbol("plus.forwardslash.minus"), nil) }),
                TabProvider(
                    schemes: ["commit"], make: { CommitMessageTab(uri: $0, app: app) },
                    placeholder: { uri in
                        let amend = URLComponents(string: uri)?.queryItems?.contains { $0.name == "amend" } == true
                        return (CommitMessageTab.title(amend: amend), .symbol("square.and.pencil"), nil)
                    })
            ],
            // `rowMarks`: an agent's tile in the Dock strip shows its workspace's CI, as the folder's sidebar row does.
            // `sessionHidden`: an agent writing a commit has no tab and no row until the user picks Show.
            // `rowMenu`: the switch for a merged PR, in its project's menu.
            rowMarks: [{ row in RowMarks.of(app).tile(row).map { [$0] } ?? [] }],
            sessionHidden: [{ panel.controller?.hiddenAgentSessions ?? [] }],
            rowMenu: [
                { row, menu in
                    guard case .project(let id) = row, let folder = app.gitFolder(project: id) else { return }
                    MergedPR(app: app).addItems(to: menu, folder)
                }
            ],
            // The window bar's branch chip: what runs on the branch, and its popover.
            branch: BranchActions(
                running: { GitSync.state(app).running[$0]?.title },
                popover: { worktree, popover in
                    let controller = SyncPopover(app: app, worktree: worktree)
                    controller.popover = popover
                    return controller
                },
                fetch: { BackgroundFetch.of(app).chip($0) }),
            // The CI and PR marks beside folders and on the window bar, and the PR in a folder's hover card.
            ci: FolderCI(
                rows: { RowMarks.of(app).sidebarMarks },
                row: { RowMarks.of(app).sidebarCI($0) },
                chip: { RowMarks.of(app).chip($0) },
                line: { RowMarks.of(app).ciLine($0) },
                open: { RowMarks.of(app).openCI($0) },
                menu: { RowMarks.of(app).menuItems($0, worktree: $1) },
                pr: { PullRequests.mark($0, app) },
                mark: CIMark.made,
                card: { PullRequests.card($0, app) },
                carded: { RowMarks.of(app).carded = $0 })
        )
    }
}

@MainActor
/// The Source Control panel on screen (built when first shown), for the commands that go through it. There is one per
/// app, because `contribute` runs again on every registry reload while the panel built first stays.
private final class LivePanel { weak var controller: SourceControlController? }

@MainActor
private func remote(
    _ app: AppModel, _ panel: LivePanel, _ op: GitRemoteOp.Step, _ done: String,
    _ viaPanel: (SourceControlController) -> Void
) {
    guard let workspace = app.workbench.workspaceId else { return }
    if let controller = panel.controller, controller.worktreeId == workspace {
        viaPanel(controller)
        return
    }
    Task {
        if let error = await GitSync.run(app, workspace, [op]) {
            Banner.show(error, style: .error)
        } else {
            Banner.show(done)
        }
    }
}

/// The graph's commit menu as commands, for the commit selected there.
@MainActor
private func commitCommands(_ panel: LivePanel) -> [CommandSpec] {
    CommitAction.allCases.map { action in
        CommandSpec(
            id: "git.commit.\(action.rawValue)", title: action.command,
            enabled: { panel.controller?.canAct(action) == true }
        ) { _ in
            guard let controller = panel.controller, let commit = controller.selectedCommit, controller.canAct(action)
            else { return }
            controller.act(action, on: commit)
        }
    }
}

/// Stashes the changes of the workspace on screen, or pops its newest stash: through the panel when it shows that
/// workspace (for its progress), else straight to git.
@MainActor
private func stash(_ app: AppModel, _ panel: LivePanel, pop: Bool) {
    guard let workspace = app.workbench.workspaceId else { return }
    let done = pop ? nil : String(localized: "Changes stashed")
    let method = { (id: String) in GitStash(id: id, pop: pop ? true : nil) }
    if let controller = panel.controller, controller.worktreeId == workspace {
        return controller.run(done: done, method)
    }
    Task {
        if await app.call(method(workspace)) != nil, let done { Banner.show(done) }
    }
}

/// A step between the changes or the comments of the diff in front. It is off elsewhere, and while a comment or a line
/// is being typed in the diff, so the key goes on to the editor or the field.
@MainActor
private func step(
    _ app: AppModel, _ id: String, _ title: String, _ key: String, _ dir: Int
) -> CommandSpec {
    let comments = id.hasSuffix("Comment")
    func diff() -> DiffTab? {
        guard let tab = app.workbench.focusedContent as? DiffTab, !(tab.view.window?.firstResponder is NSText) else {
            return nil
        }
        return tab
    }
    return CommandSpec(id: id, title: title, key: key, enabled: { diff() != nil }) { _ in
        diff()?.jump(dir, comments: comments)
    }
}

/// The branch of the workspace on screen, as the daemon last pushed it (the branch chip reads the same). It is nil on a
/// detached HEAD and outside a repository.
@MainActor
private func branchName(_ app: AppModel) -> String? {
    app.latest(GitEvent.self, app.gitKey(app.workbench.workspaceId))?.branches?.current
}

/// Where a branch's CI shows, read only here. The branch chip's setting is in Core, for its labels in Settings.
extension SettingKeys {
    static let ciSidebar = Setting("workbench.ci.sidebar", true)
    static let ciPopover = Setting("workbench.ci.popover", true)
}
