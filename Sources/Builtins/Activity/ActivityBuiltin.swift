import AppKit
import Core
import KelpKit

extension Builtins {

    /// The Activity built-in is off on a clean install; the user turns it on in Settings › Extensions.
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

// How the app keeps what the daemon pushes about activity. These event kinds belong to the Activity built-in, not
// to the shell.
extension ActivityEvent: Pushed {
    package var key: String { "" }
    package static var forgottenWith: WatchTopic? { .activity }
}
