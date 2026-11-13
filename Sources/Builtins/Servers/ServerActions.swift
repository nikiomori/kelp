import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
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
        app.workbench.starter?.run(command: command, title: title)
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

/// A server's readings as the header, the hover card and the server's tab all say them.
enum ServerReading {
    /// From 90 % a reading is strained: its number, bar or line turns orange.
    static func strained(_ share: Double) -> Bool { share >= 0.9 }
    static let strainedColor = Color(nsColor: .textOrange)
    /// "1.2 GB / 4 GB"; nil without both.
    static func used(_ used: Int?, _ total: Int?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return "\(bytes(used)) / \(bytes(total))"
    }
    /// Bytes in the unit `total` is said in, so the two read together: "0.99 GB" of "1.93 GB", not "1,014.3 MB".
    static func amount(_ n: Int, like total: Int) -> String {
        let units: [(String, Int, Int)] = [("TB", 40, 2), ("GB", 30, 2), ("MB", 20, 1), ("KB", 10, 0)]
        guard let (name, shift, digits) = units.first(where: { total >= 1 << $0.1 }) else { return bytes(n) }
        let value = Double(n) / Double(1 << shift)
        return value.formatted(.number.precision(.fractionLength(digits))) + " " + name
    }
    /// Bytes a second, "14 KB/s".
    static func rate(_ perSecond: Double) -> String {
        perSecond < 1000 ? "\(Int(perSecond.rounded())) B/s" : bytes(Int(perSecond), file: true) + "/s"
    }
    /// A share 0–100 as ps says it, "0.4%".
    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    /// What follows the program on its command line ("worker process", "/usr/bin/fail2ban-server -xf start"); empty for a
    /// kernel thread.
    static func arguments(_ process: HostStats.Process) -> String {
        guard !process.args.hasPrefix("[") else { return "" }
        let words = process.args.split(separator: " ", maxSplits: 1)
        return words.count == 2 ? String(words[1]) : ""
    }

    /// What a process is part of, as a symbol and a name: its Docker container, else its systemd unit (a service by its
    /// name, a login's scope as one). Its Kelp agent comes first, but that's the row's to show.
    static func place(_ process: HostStats.Process) -> (symbol: String, name: String)? {
        if let container = process.container { return ("shippingbox", container) }
        guard let unit = process.unit else { return nil }
        if unit.hasPrefix("session-") { return ("terminal", String(localized: "Login session")) }
        for suffix in [".service", ".scope"] where unit.hasSuffix(suffix) {
            return ("gearshape", String(unit.dropLast(suffix.count)))
        }
        return ("gearshape", unit)
    }

    /// The load averages, "0.52 0.40 0.31" (`separator` between them).
    static func load(_ stats: HostStats, separator: String = " ") -> String? {
        stats.load.map { $0.map { String(format: "%.2f", $0) }.joined(separator: separator) }
    }
}

/// Ports forwarded from each server this run of Kelp, host → its port → the port on this Mac: the server's tab, closed
/// and opened again, still says where each one is.
@MainActor @Observable
final class ServerForwards {
    var ports: [String: [Int: Int]] = [:]
}
