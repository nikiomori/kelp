import AppKit
import Core
import WorkbenchKit

/// The machines remote projects are on, as Quick Open and the sidebar's headings see them, and the server's page
/// ("host:<name>"). What a server shows (its header's meters, its hover card, its tab) is the Servers built-in's.
extension AppModel {
    /// Each host a project is on, in the projects' order.
    var remoteHosts: [String] {
        var seen = Set<String>()
        return repos.compactMap { RemoteHost.of($0.path)?.host }.filter { seen.insert($0).inserted }
    }

    /// The projects on `host`, in their order.
    func projects(onServer host: String) -> [Repo] { repos.filter { RemoteHost.of($0.path)?.host == host } }
}

extension Workbench {
    /// The server's page, a place of its own like a project's screen (its header in the sidebar stands for it).
    package func openServer(_ host: String) { show(page: TabURI.server(host)) }

    /// The Open over SSH sheet, already connecting to `host`.
    package func addProject(onServer host: String) { RemoteSheet.show(app, start: host) }
}

extension TabURI {
    /// A remote host's tab.
    static func server(_ host: String) -> String { "host:" + host }
}
