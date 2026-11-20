import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    /// A remote project's machine as a tab ("host:<name>"): how it is doing, what runs there, Kelp's agents on it, and
    /// its ports. It opens from the server's heading in the sidebar, from its menu, and from Quick Open.
    package static let servers = Builtin(
        "kelp.servers", "Servers", "How each SSH server is doing: CPU, memory, disk, processes and agents.",
        icon: "server.rack"
    ) { app in
        return Contributions(
            // What the server's tab in front does from its bar and its ⋯ menu.
            commands: [
                serverCommand(app, "servers.terminal", "Open Terminal on Server") {
                    ServerActions.runOnServer(app, $0)
                },
                serverCommand(app, "servers.htop", "Open htop on Server") { ServerActions.openHtop(app, $0) },
                serverCommand(
                    app, "servers.disconnect", "Disconnect Server…",
                    when: { app.latest(HostEvent.self, $0)?.stats.connected == true }
                ) { ServerActions.disconnectServer(app, $0) }
            ],
            tabs: [
                TabProvider(
                    schemes: ["host"], make: { serverTab(uri: $0, app: app) },
                    placeholder: { (TabURI.body($0), .symbol("server.rack"), nil) })
            ],
            // The menu of a server's header, and the same items in a remote project's menu.
            rowMenu: [
                { row, menu in
                    switch row {
                    case .host(let host): ServerHeaders.serverMenu(menu, host, app)
                    case .project(let id):
                        guard let host = app.repo(id).flatMap({ RemoteHost.of($0.path)?.host }) else { return }
                        ServerHeaders.serverItems(menu, host, app)
                    default: return
                    }
                }
            ],
            // The sidebar's server cards: the header above a host's projects, and a remote project's hover card.
            servers: ServerCards(
                header: { ServerHeader(host: $0, app: app, row: $1) },
                section: { AnyView(ServerSection(app: app, host: $0, close: $1)) },
                listed: { ServerHeaders.watchHosts($0, app) })
        )
    }
}

extension Builtins {
    /// A command for the server whose tab is in front, enabled while `when` holds for it; elsewhere it beeps.
    fileprivate static func serverCommand(
        _ app: AppModel, _ id: String, _ title: String, when: @escaping @MainActor (String) -> Bool = { _ in true },
        _ run: @escaping @MainActor (String) -> Void
    ) -> CommandSpec {
        @MainActor func front() -> String? {
            guard let uri = app.workbench.focusedContent?.uri, TabURI.scheme(uri) == "host" else { return nil }
            return TabURI.body(uri)
        }
        return CommandSpec(id: id, title: title, enabled: { front().map { when($0) } ?? false }) { _ in
            guard let host = front() else { return NSSound.beep() }
            run(host)
        }
    }
}
