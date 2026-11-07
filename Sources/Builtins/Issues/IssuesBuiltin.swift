import Agents
import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    package static let issues = Builtin(
        "kelp.issues", "Issues & Pull Requests",
        "GitHub, Linear, Jira and Bitbucket: start work from an issue, review PRs.",
        icon: "checklist"
    ) { app in
        var contributions = Contributions()
        let failed = FailedRuns(app: app)
        contributions.panels = [
            PanelSpec(id: "issues", title: "Issues & Pull Requests", icon: "checklist", extensionId: "kelp.issues") {
                let tasks = TasksViewController(app: app)
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
            ) { CIRunsController(app: app) }
        ]
        contributions.tabs = [TabProvider(schemes: ["cilog"]) { CILogTab(uri: $0, app: app) }]
        contributions.settings = [
            SettingsSection(
                id: "integrations", title: "Integrations", icon: "link", specs: [],
                custom: { AnyView(IntegrationsSettings(app: app)) },
                keywords: ["GitHub", "GitLab", "Jira", "Bitbucket", "Linear"], order: 90)
        ]
        // The workspace's project on GitHub / GitLab / Bitbucket, in the default browser.
        contributions.commands = [
            cmd("forge.openRepo", "Open Repository in Browser") { Forge.open(app, \.repo) },
            cmd("forge.openCI", "Open CI/CD in Browser") { Forge.open(app, \.ci) },
            cmd("forge.openPulls", "Open Pull Requests in Browser") { Forge.open(app, \.pulls) },
            cmd("forge.openIssues", "Open Issues in Browser") { Forge.open(app, \.issues) }
        ]
        return contributions
    }
}
