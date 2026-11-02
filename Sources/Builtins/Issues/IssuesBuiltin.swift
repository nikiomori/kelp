import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit
import KelpKit

extension Builtins {

    package static let issues = Builtin("kelp.issues", "Issues & Pull Requests", "GitHub, Linear, Jira and Bitbucket: start work from an issue, review PRs.",
                                        icon: "checklist") { app in
        var c = Contributions()
        let failed = FailedRuns(app: app)
        c.panels = [PanelSpec(id: "issues", title: "Issues & PRs", icon: "checklist", extensionId: "kelp.issues") {
            let t = TasksViewController(app: app)
            track(owner: t) { app.workbench.workspaceId } changed: { [weak t] in t?.show(worktree: $0) }
            return t
        }, PanelSpec(id: "ci", title: "CI Runs", icon: "checkmark.seal", extensionId: "kelp.issues", badge: { failed.badge }) { CIRunsController(app: app) }]
        c.tabs = [TabProvider(schemes: ["cilog"]) { CILogTab(uri: $0, app: app) }]
        c.settings = [SettingsSection(id: "integrations", title: "Integrations", icon: "link", specs: [],
                                      custom: { AnyView(IntegrationsSettings(app: app)) },
                                      keywords: ["GitHub", "GitLab", "Jira", "Bitbucket", "Linear"], order: 90)]
        // The workspace's project on GitHub / GitLab / Bitbucket, in the default browser.
        c.commands = [cmd("forge.openRepo", "Open Repository in Browser") { Forge.open(app, \.repo) },
                      cmd("forge.openCI", "Open CI/CD in Browser") { Forge.open(app, \.ci) },
                      cmd("forge.openPulls", "Open Pull Requests in Browser") { Forge.open(app, \.pulls) },
                      cmd("forge.openIssues", "Open Issues in Browser") { Forge.open(app, \.issues) }]
        return c
    }
}
