import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit
import KelpKit

extension Builtins {

    package static let git = Builtin("kelp.git", "Git", "Source Control: changes and staging, commits, branches, the history graph and diffs.",
                                     icon: "arrow.triangle.branch") { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["diff"]) { DiffTab(uri: $0, app: app) },
                  TabProvider(schemes: ["commit"]) { CommitMessageTab(uri: $0, app: app) }]
        let changed = ChangedFiles(app: app)
        let panel = LivePanel()
        c.panels = [PanelSpec(id: "git.changes", title: "Source Control", icon: "arrow.triangle.branch", extensionId: "kelp.git",
                              badge: { changed.count > 0 ? PanelBadge(count: changed.count) : nil }) {
            let p = SourceControlController(app: app)
            panel.controller = p
            return p
        }]
        c.editors = [EditorSpec(id: "git.review", title: "Review Changes", icon: "plus.forwardslash.minus",
                                uri: { ctx in ctx.workspace.map { DiffTab.uri($0.id) } })]
        c.settings = [SettingsSection(id: "git", title: "Git", icon: "arrow.triangle.branch", specs: [
            s("git.branchPrefix", "Branch prefix", "string", "", "Added to branches Kelp names, e.g. “niko/”.")
        ])]
        c.commands = [
            CommandSpec(id: "git.review", title: "Git: Review Changes", key: "shift+cmd+r") { _ in
                if let w = app.workbench.workspaceId { app.workbench.open(DiffTab.uri(w)) }
            },
            CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request") { _ in
                if let w = app.workbench.workspaceId { PRActions(app).create(worktree: w) }
            },
            // The panel's quick actions, with their keys: through the panel when it's built (its message, its progress).
            CommandSpec(id: "git.commit", title: "Git: Commit", key: "opt+cmd+c") { _ in
                if let p = panel.controller, p.worktreeId == app.workbench.workspaceId { p.commitPressed() }
                else if let w = app.workbench.workspaceId { app.workbench.open(CommitMessageTab.uri(w)) }
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
        return c
    }
}

/// The Source Control panel once it's built (it's built when first shown).
@MainActor
private final class LivePanel { weak var controller: SourceControlController? }

@MainActor
private func remote(_ app: AppModel, _ panel: LivePanel, _ op: String, _ done: String, _ viaPanel: (SourceControlController) -> Void) {
    guard let w = app.workbench.workspaceId else { return }
    if let p = panel.controller, p.worktreeId == w { viaPanel(p); return }
    Task { if await app.call(GitRemoteOp(id: w, op: op)) != nil { Banner.show(done) } }
}
