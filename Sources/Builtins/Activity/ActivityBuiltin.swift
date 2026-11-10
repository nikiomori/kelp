import AppKit
import Core
import KelpKit

extension Builtins {

    /// Off on a clean install: Settings › Extensions turns it on.
    package static let activity = Builtin(
        "kelp.activity", "Activity", "CPU and memory of each agent and terminal, with Stop.",
        icon: "gauge.with.dots.needle.33percent", offByDefault: true
    ) { app in
        return Contributions(
            panels: [
                PanelSpec(
                    id: "activity", title: "Activity", icon: "gauge.with.dots.needle.33percent",
                    extensionId: "kelp.activity"
                ) {
                    ActivityController(app: app)
                }
            ]
        )
    }
}

// How the app keeps what the daemon pushes about activity: Activity's own kinds, not the shell's.
extension ActivityEvent: Pushed {
    package var key: String { "" }
    package static var forgottenWith: WatchTopic? { .activity }
}
