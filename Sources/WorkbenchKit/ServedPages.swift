import Core
import Foundation

/// A server a workspace runs, as this Mac reaches it.
public struct ServedPage: Equatable, Sendable {
    public var url: String
    /// On this Mac; where a host's port isn't forwarded yet, the number it would like.
    public var port: Int
    public var pid: Int32?, command: String
    /// false: a database or a debugger, whose address is copied rather than opened.
    public var isWeb: Bool
    /// On a remote project: the host, and the port there.
    public var host: String?, remotePort: Int
    /// Reachable from this Mac as it stands; always so for this Mac's own.
    public var forwarded: Bool
    /// The host can't be asked: this is its last answer.
    public var offline: Bool

    public var address: String { "localhost:\(port)" }
    /// Where it really is, for tips and the Run menu: "devbox:5432 → :5433".
    public var place: String {
        guard let host else { return address }
        return "\(host):\(remotePort)" + (forwarded && port != remotePort ? " → :\(port)" : "")
    }

    public init(_ p: PortsList.Port) {
        port = p.here ?? p.port
        url = "http://localhost:\(port)"
        pid = p.pid > 0 ? p.pid : nil
        command = p.command
        isWeb = !ServedPages.notWebPrograms.contains(p.command) && !ServedPages.notWebPorts.contains(p.port)
        host = p.host
        remotePort = p.port
        forwarded = p.host == nil || p.here != nil
        offline = p.offline == true
    }
    init(url: String, port: Int) {
        self.url = url
        self.port = port
        command = ""
        isWeb = true
        remotePort = port
        forwarded = true
        offline = false
    }

    /// As this Mac reaches it: one on a host comes here first through `call` (the app's `PortsForward`), and a dropped
    /// connection is opened again. nil when it can't be; `call` has said why.
    @MainActor public func reached(in wid: String, call: @MainActor (PortsForward) async -> PortsForward.Forwarded?)
        async -> ServedPage?
    {
        guard host != nil, !forwarded || offline else { return self }
        guard let f = await call(PortsForward(worktreeId: wid, port: remotePort)) else { return nil }
        var here = self
        here.moved(to: f.port)
        return here
    }

    /// Brought to port `here` on this Mac.
    public mutating func moved(to here: Int) {
        if var u = URLComponents(string: url) {
            u.port = here
            url = u.string ?? url
        }
        port = here
        forwarded = true
        offline = false
    }
}

public enum ServedPages {
    static let notWebPrograms: Set = ["postgres", "mysqld", "mariadbd", "mongod", "redis-server", "memcached"]
    /// Their usual ports, for a server inside a container or a wrapper: 9229 is Node's debugger.
    static let notWebPorts: Set = [3306, 5432, 6379, 9229, 11211, 27017]

    /// Worth showing: from 49152 up the system hands out ports to anything that asks, which is where agents' helpers
    /// listen, and ssh only holds a remote project's forwarding.
    public static func listed(_ p: PortsList.Port) -> Bool { p.command != "ssh" && p.port < 49152 }

    /// What runs printed (their address as printed, whatever its port), then the rest of the listening ports, each port
    /// once, with pages before the addresses that aren't: the first is what a click on the capsule opens.
    public static func list(printed: [String], ports: [PortsList.Port]) -> [ServedPage] {
        var all = printed.compactMap { url -> ServedPage? in
            guard let port = URLComponents(string: url)?.port else { return nil }
            var page =
                ports.first { ($0.here ?? $0.port) == port }.map(ServedPage.init) ?? ServedPage(url: url, port: port)
            page.url = url
            page.isWeb = true
            return page
        }
        for p in ports where listed(p) && !all.contains(where: { $0.port == (p.here ?? p.port) }) {
            all.append(ServedPage(p))
        }
        return all.filter(\.isWeb) + all.filter { !$0.isWeb }
    }
}
