import AppKit
import Core
import KelpKit

extension Builtins {

    /// A remote projects' machine as a tab ("host:<name>"): how it's doing, what runs there, Kelp's agents on it, its ports.
    /// Opened from the server's heading in the sidebar, its menu and Quick Open.
    package static let servers = Builtin(
        "kelp.servers", "Servers", "How each SSH server is doing: CPU, memory, disk, processes and agents.",
        icon: "server.rack"
    ) { app in
        var contributions = Contributions()
        contributions.tabs = [TabProvider(schemes: ["host"]) { ServerTab(uri: $0, app: app) }]
        return contributions
    }
}
