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
                CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request") { _ in
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
                }
            ],
            settings: [
                SettingsSection(
                    id: "git", title: "Source Control", icon: "arrow.triangle.branch",
                    specs: [
                        s(
                            SettingKeys.branchPrefix, "Branch prefix", .string, "Added to branches Kelp names.",
                            placeholder: "you/"),
                        s(
                            SettingKeys.worktreesFolder, "Folder for worktrees", .string,
                            "Empty: inside Kelp's own folder.",
                            help:
                                "Each project's branches go in a folder named after it there, e.g. ~/worktrees. Empty: inside Kelp's own folder.",
                            placeholder: "~/worktrees"),
                        // Where a branch's CI shows. RowMarks keeps it, and gh / glab are asked only for what one of
                        // these places shows.
                        s(
                            SettingKeys.ciBranchChip, "CI on the branch chip", .enum,
                            "A ring while it runs, a red dot when it fails.",
                            help:
                                "A ring while it runs, a red dot when it fails, ◎ while a deploy waits for approval, ✓ for a minute after it passes.",
                            options: ["icon", "end", "off"],
                            labels: [
                                "icon": String(localized: "In Place of the Branch Icon"),
                                "end": String(localized: "After the Counts"), "off": String(localized: "Off")
                            ], group: "CI"),
                        s(
                            SettingKeys.ciSidebar, "CI beside folders", .boolean,
                            "In the sidebar and the ⌃Tab switcher.",
                            help:
                                "In the sidebar and the ⌃Tab switcher; ✓ until you open the folder. Off also stops checking CI for the others.",
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
                }),
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

/// Where a branch's CI shows, read only here. The branch chip's setting is in Core, for its labels in Settings.
extension SettingKeys {
    static let ciSidebar = Setting("workbench.ci.sidebar", true)
    static let ciPopover = Setting("workbench.ci.popover", true)
}

// How the app keeps what the daemon pushes about pull requests. These event kinds belong to the Git built-in, not to
// the shell.
extension PREvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .pr }
}
