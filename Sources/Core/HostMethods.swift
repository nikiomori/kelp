import Foundation

/// How a remote projects' host is doing, read in one call over its shared connection: what htop shows, plus which of its
/// processes are Kelp's agents. `connect` false (the sidebar's look every few seconds) never dials: without an open
/// connection the answer is only `connected` false and why the last try failed.
public struct HostStatsRead: InternalMethod {
    public static let name = "host.stats"; public typealias Result = HostStats
    public var host: String, connect: Bool?
    public init(host: String, connect: Bool? = nil) { self.host = host; self.connect = connect }
}

/// Closes the host's shared connection (`ssh -O exit`): agents in tmux there go on.
public struct HostDisconnect: InternalMethod {
    public static let name = "host.disconnect"; public typealias Result = Done; public var host: String
    public init(host: String) { self.host = host }
}

public struct HostStats: Codable, Sendable, Equatable {
    public var host: String
    public var connected: Bool
    /// Why the last connection failed, in ssh's words; nil once one worked.
    public var error: String?
    /// "Ubuntu 24.04.5 LTS", else `uname -sr`.
    public var os: String?
    public var cores: Int?
    /// Seconds since boot; the 1, 5 and 15 minute load averages. Linux only, the load also on macOS and BSD.
    public var uptime: Double?, load: [Double]?
    /// Busy share of all cores, 0–100, over a moment of the read. Linux only.
    public var cpu: Double?
    /// Bytes used and in all. Memory and swap: Linux only.
    public var memory: Int?, memoryTotal: Int?, swap: Int?, swapTotal: Int?, disk: Int?, diskTotal: Int?
    public var processCount: Int?
    /// The busiest processes, and every one of Kelp's agents, by CPU.
    public var processes: [Process]?
    /// TCP ports something listens on.
    public var ports: [Port]?
    /// Kelp's tmux sessions there (`Tmux.isOwn`), with the Kelp session each belongs to, if one does.
    public var tmux: [TmuxSession]?

    public init(host: String, connected: Bool, error: String? = nil) { self.host = host; self.connected = connected; self.error = error }

    public struct Process: Codable, Sendable, Equatable {
        public var pid: Int, user: String, cpu: Double
        /// Resident bytes; seconds it has run.
        public var memory: Int, seconds: Int
        /// The program's name, and its whole command line.
        public var command: String, args: String
        /// The Kelp session it runs under (its tmux pane's), if any.
        public var session: String?
        public init(pid: Int, user: String, cpu: Double, memory: Int, seconds: Int, command: String, args: String, session: String? = nil) {
            self.pid = pid; self.user = user; self.cpu = cpu; self.memory = memory; self.seconds = seconds
            self.command = command; self.args = args; self.session = session
        }
    }

    public struct Port: Codable, Sendable, Equatable {
        public var port: Int
        /// Reached only from the server itself (127.0.0.1, ::1): forward it to use it here.
        public var local: Bool
        public init(port: Int, local: Bool) { self.port = port; self.local = local }
    }

    public struct TmuxSession: Codable, Sendable, Equatable {
        public var name: String, session: String?
        public init(name: String, session: String? = nil) { self.name = name; self.session = session }
    }

    public enum Strain: String, Sendable { case disk, memory, cpu }
    /// What wants you now (the app says "Disk 92%"), nil while all's well: a disk or memory over 90 %, or every core busy for
    /// about a minute (the CPU now and the minute's load both high), worst first.
    public var alert: (Strain, percent: Int)? {
        if let d = Self.percent(disk, diskTotal), d >= 90 { return (.disk, d) }
        if let m = Self.percent(memory, memoryTotal), m >= 90 { return (.memory, m) }
        if let c = cpu, c >= 90, let l = load?.first, let n = cores, l >= Double(n) * 0.9 { return (.cpu, Int(c.rounded())) }
        return nil
    }
    public static func percent(_ used: Int?, _ total: Int?) -> Int? {
        guard let used, let total, total > 0 else { return nil }
        return Int((Double(used) / Double(total) * 100).rounded())
    }
}
