import Agents
import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    package static let git = Builtin(
        "kelp.git", "Source Control", "Changes and staging, commits, branches, the history graph and diffs, with Git.",
        icon: "arrow.triangle.branch"
    ) { app in
        var contributions = Contributions()
        contributions.tabs = [
            TabProvider(schemes: ["diff"]) { DiffTab(uri: $0, app: app) },
            TabProvider(schemes: ["commit"]) { CommitMessageTab(uri: $0, app: app) }
        ]
        let changed = ChangedFiles(app: app)
        let panel = LivePanel()
        contributions.panels = [
            PanelSpec(
                id: "git.changes", title: "Source Control", icon: "arrow.triangle.branch", extensionId: "kelp.git",
                role: .changes,
                badge: { changed.count > 0 ? PanelBadge(count: changed.count) : nil }
            ) {
                let controller = SourceControlController(app: app)
                panel.controller = controller
                return controller
            }
        ]
        contributions.editors = [
            EditorSpec(
                id: "git.review", title: "Review Changes", icon: "plus.forwardslash.minus",
                uri: { ctx in ctx.workspace.map { DiffTab.uri($0.id) } })
        ]
        contributions.settings = [
            SettingsSection(
                id: "git", title: "Source Control", icon: "arrow.triangle.branch",
                specs: [
                    s(
                        "git.branchPrefix", "Branch prefix", "string", "", "Added to branches Kelp names.",
                        placeholder: "you/"),
                    s(
                        "worktrees.folder", "Folder for worktrees", "string", "",
                        "Empty: inside Kelp's own folder.",
                        help:
                            "Each project's branches go in a folder named after it there, e.g. ~/worktrees. Empty: inside Kelp's own folder.",
                        placeholder: "~/worktrees"),
                    // Where a branch's CI shows (RowBadges keeps it; gh / glab are asked only for what one of these shows).
                    s(
                        "workbench.ci.branchChip", "CI on the branch chip", "enum", "icon",
                        "A ring while it runs, a red dot when it fails.",
                        help:
                            "A ring while it runs, a red dot when it fails, ◎ while a deploy waits for approval, ✓ for a minute after it passes.",
                        options: ["icon", "end", "off"], group: "CI"),
                    s(
                        "workbench.ci.sidebar", "CI beside folders", "boolean", true,
                        "In the sidebar and the ⌃Tab switcher.",
                        help:
                            "In the sidebar and the ⌃Tab switcher; ✓ until you open the folder. Off also stops checking CI for the others.",
                        group: "CI"),
                    s(
                        "workbench.ci.popover", "CI in the branch popover", "boolean", true,
                        "The newest run of each workflow; a click opens CI Runs.", group: "CI")
                ], order: 80)
        ]
        contributions.commands = [
            CommandSpec(id: "git.review", title: "Git: Review Changes", key: "shift+cmd+r") { _ in
                if let workspace = app.workbench.workspaceId { app.workbench.open(DiffTab.uri(workspace)) }
            },
            CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request") { _ in
                if let workspace = app.workbench.workspaceId { PRActions(app).create(worktree: workspace) }
            },
            // The panel's quick actions, with their keys: through the panel when it's built (its message, its progress).
            CommandSpec(id: "git.commit", title: "Git: Commit", key: "opt+cmd+c") { _ in
                if let controller = panel.controller, controller.worktreeId == app.workbench.workspaceId {
                    controller.commitPressed()
                } else if let workspace = app.workbench.workspaceId {
                    app.workbench.open(CommitMessageTab.uri(workspace))
                }
            },
            CommandSpec(id: "git.pull", title: "Git: Pull", key: "opt+cmd+x") { _ in
                remote(app, panel, "pull", String(localized: "Pulled")) { $0.pullPressed() }
            },
            CommandSpec(id: "git.push", title: "Git: Push", key: "opt+cmd+p") { _ in
                remote(app, panel, "push", String(localized: "Pushed")) { $0.pushPressed() }
            },
            CommandSpec(id: "git.fetch", title: "Git: Fetch", key: "opt+cmd+f") { _ in
                remote(app, panel, "fetch", String(localized: "Fetched")) { $0.fetchPressed() }
            }
        ]
        // The window bar's branch chip: what runs, its popover, and a pull a merged PR asks for.
        contributions.branch = BranchActions(
            running: { GitSync.state(app).running[$0] },
            popover: { worktree, popover in
                let controller = SyncPopover(app: app, worktree: worktree)
                controller.popover = popover
                return controller
            },
            sync: { await GitSync.run(app, $0, $1) })
        return contributions
    }
}

/// The Source Control panel once it's built (it's built when first shown).
@MainActor
private final class LivePanel { weak var controller: SourceControlController? }

@MainActor
private func remote(
    _ app: AppModel, _ panel: LivePanel, _ op: String, _ done: String, _ viaPanel: (SourceControlController) -> Void
) {
    guard let workspace = app.workbench.workspaceId else { return }
    if let controller = panel.controller, controller.worktreeId == workspace {
        viaPanel(controller)
        return
    }
    Task { if await app.call(GitRemoteOp(id: workspace, op: op)) != nil { Banner.show(done) } }
}
