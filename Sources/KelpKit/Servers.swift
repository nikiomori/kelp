import AppKit
import Core
import DesignKit
import WorkbenchKit

/// The machines remote projects are on, as the sidebar's headings, the hover card and the server tab ("host:<name>") see them.
extension AppModel {
    /// Each host a project is on, in the projects' order.
    var remoteHosts: [String] {
        var seen = Set<String>()
        return repos.compactMap { RemoteHost.of($0.path)?.host }.filter { seen.insert($0).inserted }
    }

    /// The screen the server's terminal and htop open on: its first project's own.
    package func serverWorkspace(_ host: String) -> String? {
        guard let r = repos.first(where: { RemoteHost.of($0.path)?.host == host }) else { return nil }
        return mainWorkspace(of: r, among: worktrees)?.id
    }

    /// The server's page, a place of its own like a project's screen (its header in the sidebar stands for it).
    func openServer(_ host: String) { workbench.show(page: TabURI.server(host)) }

    /// A terminal on the host (nil `command`: its shell), in its project's folder, beside the server's tab.
    package func runOnServer(_ host: String, command: String? = nil, title: String? = nil) {
        guard let wid = serverWorkspace(host) else { return }
        workbench.show(workspace: wid)
        workbench.editor?.run(command: command, title: title)
    }

    /// htop where the host has it, else top.
    package func openHtop(_ host: String) {
        runOnServer(host, command: "command -v htop >/dev/null 2>&1 && exec htop || exec top", title: "htop")
    }

    /// The Open over SSH sheet, already connecting to `host`.
    package func addProject(onServer host: String) { RemoteSheet.show(self, start: host) }

    /// Closes the shared connection; agents in tmux there go on.
    package func disconnectServer(_ host: String) { Task { _ = await call(HostDisconnect(host: host)) } }

    /// The projects on `host`, in their order.
    func projects(onServer host: String) -> [Repo] { repos.filter { RemoteHost.of($0.path)?.host == host } }

    /// What a server's heading says, and in what colour: nothing while it's fine, and what's wrong otherwise.
    func serverWord(_ host: String) -> (text: String, color: NSColor)? {
        guard let s = latest(HostEvent.self, host)?.stats else { return nil }
        if !s.connected {
            return s.error == nil
                ? (String(localized: "Not connected"), .secondaryLabelColor)
                : (String(localized: "Can't reach"), .textRed)
        }
        guard let (what, p) = s.alert else { return nil }
        switch what {
        case .disk: return (String(localized: "Disk \(p)%"), .textOrange)
        case .memory: return (String(localized: "Memory \(p)%"), .textOrange)
        case .cpu: return (String(localized: "CPU \(p)%"), .textOrange)
        }
    }
}

extension TabURI {
    /// A remote host's tab.
    static func server(_ host: String) -> String { "host:" + host }
}

/// Bytes as people read them on a server: "870 MB", "3.1 GB".
package func serverBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
}

/// "3 d 10 h", "18 m", "40 s".
package func serverDuration(_ seconds: Double) -> String {
    let s = Int(seconds), d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
    if h > 0 { return m > 0 ? "\(h) h \(m) m" : "\(h) h" }
    return m > 0 ? "\(m) m" : "\(s) s"
}
