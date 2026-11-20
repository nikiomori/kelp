import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    package static let issues = Builtin(
        "kelp.issues", "Issues & Pull Requests",
        "GitHub, Linear, Jira and Bitbucket: start work from an issue, review PRs.",
        icon: "checklist"
    ) { app in
        let failed = FailedRuns(app: app), watch = PRWatch(app: app)
        let ci: LivePanel = app.part { LivePanel() }   // the one the panel on screen was built with, at every reload
        return Contributions(
            panels: [
                PanelSpec(
                    id: "issues", title: "Issues & Pull Requests", icon: "checklist", extensionId: "kelp.issues",
                    badge: { watch.badge }
                ) {
                    let tasks = TasksViewController(app: app, watch: watch)
                    track(owner: tasks) {
                        app.workbench.workspaceId
                    } changed: { [weak tasks] in
                        tasks?.show(worktree: $0)
                    }
                    return tasks
                },
                PanelSpec(
                    id: "ci", title: "CI Runs", icon: "checkmark.seal", extensionId: "kelp.issues", role: .checks,
                    badge: { failed.badge }
                ) {
                    let controller = CIRunsController(app: app)
                    ci.controller = controller
                    return controller
                }
            ],
            // The workspace's project on GitHub / GitLab / Bitbucket, in the default browser.
            commands: [
                cmd("forge.openRepo", "Open Repository in Browser") { Forge.open(app, \.repo) },
                cmd("forge.openCI", "Open CI/CD in Browser") { Forge.open(app, \.ci) },
                cmd("forge.openPulls", "Open Pull Requests in Browser") { Forge.open(app, \.pulls) },
                cmd("forge.openIssues", "Open Issues in Browser") { Forge.open(app, \.issues) },
                // CI Runs' actions, for the run or job picked in the panel.
                ciCommand(ci, "ci.rerunFailed", "CI: Re-run Failed", .rerunFailed),
                ciCommand(ci, "ci.rerunAll", "CI: Re-run All", .rerunAll),
                ciCommand(ci, "ci.cancel", "CI: Cancel Run…", .cancel),
                ciCommand(ci, "ci.runWorkflow", "CI: Run Workflow…", .runWorkflow),
                ciCommand(ci, "ci.fix", "CI: Fix with Agent", .fix),
                ciCommand(ci, "ci.openLog", "CI: Open Full Log", .openLog),
                // The pull request's or the issue's tab in front.
                CommandSpec(
                    id: "forge.reviewWithAgent", title: "Pull Request: Review with Agent",
                    enabled: { forgeTab(app)?.prView != nil }
                ) { _ in
                    forgeTab(app)?.reviewWithAgent()
                },
                CommandSpec(
                    id: "forge.startOnBranch", title: "Issue: Start on Own Branch",
                    enabled: { forgeTab(app)?.issueView?.issue.state == "OPEN" }
                ) { _ in
                    forgeTab(app)?.startOnBranch()
                }
            ],
            settings: [
                SettingsSection(
                    id: "integrations", title: "Integrations", icon: "link", specs: [],
                    custom: { AnyView(IntegrationsSettings(app: app)) },
                    keywords: ["GitHub", "GitLab", "Jira", "Bitbucket", "Linear"], order: 90)
            ],
            tabs: [
                TabProvider(
                    schemes: ["cilog"], make: { CILogTab(uri: $0, app: app) },
                    placeholder: { (CILogTab.title($0), .symbol("doc.text"), nil) }),
                TabProvider(
                    schemes: ["pr", "issue"], make: { ForgeItemTab(uri: $0, app: app) },
                    placeholder: {
                        (
                            ForgeItemTab.title($0),
                            .symbol($0.hasPrefix("pr:") ? "arrow.triangle.pull" : "smallcircle.filled.circle"), nil
                        )
                    })
            ],
            // ⌘P "#123" or "#login": the project's open pull requests.
            quickPrefixes: ["#": { watch.quickRows($0) }]
        )
    }
}

@MainActor
/// The CI Runs panel on screen (built when first shown), for the commands that act on its pick. There is one per app,
/// because `contribute` runs again on every registry reload while the panel built first stays.
private final class LivePanel { weak var controller: CIRunsController? }

/// A command for CI Runs' pick, enabled while the panel shows a pick it can act on.
@MainActor
private func ciCommand(_ ci: LivePanel, _ id: String, _ title: String, _ what: CIRunsController.Command)
    -> CommandSpec
{
    CommandSpec(id: id, title: title, enabled: { ci.controller?.command(what) != nil }) { _ in
        if let run = ci.controller?.command(what) { run() } else { NSSound.beep() }
    }
}

/// The pull request or issue in the focused tab.
@MainActor
private func forgeTab(_ app: AppModel) -> ForgeItemTab? { app.workbench.focusedContent as? ForgeItemTab }
