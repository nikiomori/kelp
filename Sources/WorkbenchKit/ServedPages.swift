import Core
import Foundation

/// A server a workspace runs, as this Mac reaches it.
public struct ServedPage: Equatable, Sendable {
    public var url: String, port: Int, pid: Int32?
    /// false: a database or a debugger, whose address is copied rather than opened.
    public var isWeb: Bool
    public var address: String { "localhost:\(port)" }

    public init(_ p: PortsList.Port) {
        url = "http://localhost:\(p.port)"
        port = p.port
        pid = p.pid
        isWeb = !ServedPages.notWebPrograms.contains(p.command) && !ServedPages.notWebPorts.contains(p.port)
    }
    init(url: String, port: Int, pid: Int32?) { self.url = url; self.port = port; self.pid = pid; isWeb = true }
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
        var all = printed.compactMap { url in
            URLComponents(string: url)?.port.map { port in ServedPage(url: url, port: port, pid: ports.first { $0.port == port }?.pid) }
        }
        for p in ports where listed(p) && !all.contains(where: { $0.port == p.port }) { all.append(ServedPage(p)) }
        return all.filter(\.isWeb) + all.filter { !$0.isWeb }
    }
}
