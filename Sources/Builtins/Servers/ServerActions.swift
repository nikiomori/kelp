import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// What can be done on the machines remote projects are on, from the sidebar's headings, the hover card and the server
/// tab ("host:<name>").
@MainActor
enum ServerActions {
    /// The screen the server's terminal and htop open on: its first project's own.
    static func serverWorkspace(_ app: AppModel, _ host: String) -> String? {
        guard let project = app.repos.first(where: { RemoteHost.of($0.path)?.host == host }) else { return nil }
        return mainWorkspace(of: project, among: app.worktrees)?.id
    }

    /// A terminal on the host (nil `command`: its shell), in its project's folder, beside the server's tab.
    static func runOnServer(_ app: AppModel, _ host: String, command: String? = nil, title: String? = nil) {
        guard let wid = serverWorkspace(app, host) else { return }
        app.workbench.show(workspace: wid)
        app.workbench.editor?.run(command: command, title: title)
    }

    /// htop where the host has it, else top.
    static func openHtop(_ app: AppModel, _ host: String) {
        runOnServer(app, host, command: "command -v htop >/dev/null 2>&1 && exec htop || exec top", title: "htop")
    }

    /// Closes the shared connection; agents in tmux there go on.
    static func disconnectServer(_ app: AppModel, _ host: String) {
        Task { _ = await app.call(HostDisconnect(host: host)) }
    }

    /// What a server's heading says, and in what colour: nothing while it's fine, and what's wrong otherwise.
    static func serverWord(_ app: AppModel, _ host: String) -> (text: String, color: NSColor)? {
        guard let stats = app.latest(HostEvent.self, host)?.stats else { return nil }
        if !stats.connected {
            return stats.error == nil
                ? (String(localized: "Not connected"), .secondaryLabelColor)
                : (String(localized: "Can't reach"), .textRed)
        }
        guard let (what, p) = stats.alert else { return nil }
        switch what {
        case .disk: return (String(localized: "Disk \(p)%"), .textOrange)
        case .memory: return (String(localized: "Memory \(p)%"), .textOrange)
        case .cpu: return (String(localized: "CPU \(p)%"), .textOrange)
        }
    }
}

/// "3 d 10 h", "18 m", "40 s".
func serverDuration(_ seconds: Double) -> String {
    let total = Int(seconds), days = total / 86400, hours = total % 86400 / 3600, minutes = total % 3600 / 60
    if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
    if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) m" : "\(hours) h" }
    return minutes > 0 ? "\(minutes) m" : "\(total) s"
}
