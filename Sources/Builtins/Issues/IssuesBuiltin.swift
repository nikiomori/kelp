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
                ) { CIRunsController(app: app) }
            ],
            // The workspace's project on GitHub / GitLab / Bitbucket, in the default browser.
            commands: [
                cmd("forge.openRepo", "Open Repository in Browser") { Forge.open(app, \.repo) },
                cmd("forge.openCI", "Open CI/CD in Browser") { Forge.open(app, \.ci) },
                cmd("forge.openPulls", "Open Pull Requests in Browser") { Forge.open(app, \.pulls) },
                cmd("forge.openIssues", "Open Issues in Browser") { Forge.open(app, \.issues) }
            ],
            settings: [
                SettingsSection(
                    id: "integrations", title: "Integrations", icon: "link", specs: [],
                    custom: { AnyView(IntegrationsSettings(app: app)) },
                    keywords: ["GitHub", "GitLab", "Jira", "Bitbucket", "Linear"], order: 90,
                    tint: NSColor(hex: 0x34C759))
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
            ]
        )
    }
}
