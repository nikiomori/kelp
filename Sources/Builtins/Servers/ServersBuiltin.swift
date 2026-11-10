import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    /// A remote projects' machine as a tab ("host:<name>"): how it's doing, what runs there, Kelp's agents on it, its ports.
    /// Opened from the server's heading in the sidebar, its menu and Quick Open.
    package static let servers = Builtin(
        "kelp.servers", "Servers", "How each SSH server is doing: CPU, memory, disk, processes and agents.",
        icon: "server.rack"
    ) { app in
        return Contributions(
            tabs: [
                TabProvider(
                    schemes: ["host"], make: { ServerTab(uri: $0, app: app) },
                    placeholder: { (TabURI.body($0), .symbol("server.rack"), nil) })
            ],
            // The sidebar's server cards: the header over a host's projects, its menu, a remote project's items and hover card.
            servers: ServerCards(
                header: { ServerHeader(host: $0, app: app, row: $1) },
                menu: { ServerHeaders.serverMenu($0, $1, app) },
                projectItems: { ServerHeaders.serverItems($0, $1, app) },
                section: { AnyView(ServerSection(app: app, host: $0, close: $1)) },
                listed: { ServerHeaders.watchHosts($0, app) })
        )
    }
}
