import Foundation

/// Returns how a remote project's host is doing, read in one call over its shared connection: what htop shows, plus
/// which of its processes are Kelp's agents. With `connect` false (the sidebar's check every few seconds), it never
/// dials. Without an open connection, the answer is then only `connected` false and why the last try failed.
public struct HostStatsRead: InternalMethod {
    public static let name = "host.stats"
    public typealias Result = HostStats
    public var host: String, connect: Bool?
    public init(host: String, connect: Bool? = nil) {
        self.host = host
        self.connect = connect
    }
}

/// Returns the host's readings of the last hour, oldest first. The daemon reads a host every 10 s while its server is
/// listed and every 2 s while it is on screen. Empty for a host the daemon hasn't read since it started.
public struct HostHistoryRead: InternalMethod {
    public static let name = "host.history"
    public typealias Result = [HostStats.Sample]
    public var host: String
    public init(host: String) { self.host = host }
}

/// Closes the host's shared connection (`ssh -O exit`). Agents in tmux on the host go on.
public struct HostDisconnect: InternalMethod {
    public static let name = "host.disconnect"
    public typealias Result = Done
    public var host: String
    public init(host: String) { self.host = host }
}

public struct HostStats: Codable, Sendable, Equatable {
    public var host: String
    public var connected: Bool
    /// Why the last connection failed, in ssh's words. nil once a connection worked.
    public var error: String?
    /// The OS name, such as "Ubuntu 24.04.5 LTS", or else what `uname -sr` prints.
    public var os: String?
    public var cores: Int?
    /// The seconds since boot, and the 1, 5 and 15 minute load averages. The uptime is read on Linux only, and the load
    /// on macOS and BSD as well.
    public var uptime: Double?, load: [Double]?
    /// The busy share of all cores, 0–100, over a short moment during the read. Linux only.
    public var cpu: Double?
    /// During that moment, the share spent waiting on the disk, and the share the machine under a VM took (steal),
    /// 0–100. Linux only.
    public var iowait: Double?, steal: Double?
    /// Bytes per second in and out on the interface the default route uses, over the same moment. Linux only.
    public var network: Network?
    /// Bytes used and bytes in total. Memory and swap are read on Linux only.
    public var memory: Int?, memoryTotal: Int?, swap: Int?, swapTotal: Int?, disk: Int?, diskTotal: Int?
    public var processCount: Int?
    /// The busiest processes plus every one of Kelp's agents, sorted by CPU.
    public var processes: [Process]?
    /// The TCP ports something listens on.
    public var ports: [Port]?
    /// Kelp's tmux sessions on the host (`Tmux.isOwn`), each with the Kelp session it belongs to, if any.
    public var tmux: [TmuxSession]?
    /// The running Docker containers, when the user is allowed to ask docker.
    public var containers: [Container]?
    /// The systemd units that failed ("nginx.service"). Linux with systemd only.
    public var failedUnits: [String]?
    /// True when the system asks for a restart (Debian and Ubuntu, after an update that needs one).
    public var rebootRequired: Bool?

    public init(host: String, connected: Bool, error: String? = nil) {
        self.host = host
        self.connected = connected
        self.error = error
    }

    public struct Process: Codable, Sendable, Equatable {
        public var pid: Int, user: String, cpu: Double
        /// The process's resident bytes, and the seconds it has run.
        public var memory: Int, seconds: Int
        /// The program's name, and its whole command line.
        public var command: String, args: String
        /// The Kelp session the process runs under (through its tmux pane), if any.
        public var session: String?
        /// The systemd unit the process runs in ("nginx.service", "session-4.scope"), and the Docker container, by
        /// name. Linux only.
        public var unit: String?, container: String?
        public init(
            pid: Int, user: String, cpu: Double, memory: Int, seconds: Int, command: String, args: String,
            session: String? = nil, unit: String? = nil, container: String? = nil
        ) {
            self.pid = pid
            self.user = user
            self.cpu = cpu
            self.memory = memory
            self.seconds = seconds
            self.command = command
            self.args = args
            self.session = session
            self.unit = unit
            self.container = container
        }
    }

    public struct Port: Codable, Sendable, Equatable {
        public var port: Int
        /// The port can be reached only from the server itself (127.0.0.1, ::1), so forward it to use it here.
        public var local: Bool
        /// What listens: the program (`ss` names it only for the user's own processes), and the Docker container the
        /// port is published from.
        public var process: String?, container: String?
        public init(port: Int, local: Bool, process: String? = nil, container: String? = nil) {
            self.port = port
            self.local = local
            self.process = process
            self.container = container
        }
    }

    public struct Network: Codable, Sendable, Equatable {
        public var interface: String
        /// Bytes per second.
        public var received: Double, sent: Double
        public init(interface: String, received: Double, sent: Double) {
            self.interface = interface
            self.received = received
            self.sent = sent
        }
    }

    public struct Container: Codable, Sendable, Equatable {
        public var name: String
        /// The host ports the container is published on.
        public var ports: [Int]
        /// The CPU and memory the container's processes take together, and how long the oldest has run. nil when ps
        /// can't tell which processes are the container's.
        public var cpu: Double?, memory: Int?, seconds: Int?
        public init(name: String, ports: [Int], cpu: Double? = nil, memory: Int? = nil, seconds: Int? = nil) {
            self.name = name
            self.ports = ports
            self.cpu = cpu
            self.memory = memory
            self.seconds = seconds
        }
    }

    /// One reading for the history: when it was taken (seconds since 1970), the CPU and memory shares (0–1), and the
    /// network's bytes per second.
    public struct Sample: Codable, Sendable, Equatable {
        public var at: Double
        public var cpu: Double?, memory: Double?, received: Double?, sent: Double?
        public init(at: Double, cpu: Double?, memory: Double?, received: Double?, sent: Double?) {
            self.at = at
            self.cpu = cpu
            self.memory = memory
            self.received = received
            self.sent = sent
        }
    }

    public struct TmuxSession: Codable, Sendable, Equatable {
        public var name: String, session: String?
        public init(name: String, session: String? = nil) {
            self.name = name
            self.session = session
        }
    }

    public enum Strain: String, Sendable { case disk, memory, cpu }
    /// The problem that needs attention now (the app says "Disk 92%"), or nil while all is well. A problem is a disk or
    /// memory over 90 %, or every core busy for about a minute (the CPU now and the minute's load both high). The worst
    /// problem comes first.
    public var alert: (Strain, percent: Int)? {
        if let diskPercent = Self.percent(disk, diskTotal), diskPercent >= 90 { return (.disk, diskPercent) }
        if let memoryPercent = Self.percent(memory, memoryTotal), memoryPercent >= 90 {
            return (.memory, memoryPercent)
        }
        if let cpu, cpu >= 90, let minuteLoad = load?.first, let cores, minuteLoad >= Double(cores) * 0.9 {
            return (.cpu, Int(cpu.rounded()))
        }
        return nil
    }
    public static func percent(_ used: Int?, _ total: Int?) -> Int? {
        guard let used, let total, total > 0 else { return nil }
        return Int((Double(used) / Double(total) * 100).rounded())
    }
}

/// Returns which of `commands` a remote workspace's host has, as its login shell finds them, because agents start in
/// that shell. The agent menus offer these. It asks over ssh, which connects if it must, because someone opened the
/// menu.
public struct HostCommands: InternalMethod {
    public static let name = "host.commands"
    public typealias Result = [String]
    public var worktreeId: String, commands: [String]
    public init(worktreeId: String, commands: [String]) {
        self.worktreeId = worktreeId
        self.commands = commands
    }
}

/// Returns the key presented by a host Kelp hasn't connected to before (ssh refused it with "Host key verification
/// failed"), as ssh shows it: "SHA256:…" and its kind (ED25519). It asks the host that ~/.ssh/config sends `host` to.
/// nil when that isn't possible (a jump host in between, no answer).
public struct RemoteHostKey: InternalMethod {
    public static let name = "remote.hostKey"
    public struct Key: Codable, Sendable, Equatable {
        public var fingerprint: String, kind: String
        public init(fingerprint: String, kind: String) {
            self.fingerprint = fingerprint
            self.kind = kind
        }
    }
    public typealias Result = Key?
    public var host: String
    public init(host: String) { self.host = host }
}

/// Trusts the key of `host`, as answering ssh's "yes" does. It reads the key again and keeps it in ~/.ssh/known_hosts
/// only when it is still the one shown (`fingerprint`).
public struct RemoteTrustHost: InternalMethod {
    public static let name = "remote.trustHost"
    public typealias Result = Done
    public var host: String, fingerprint: String
    public init(host: String, fingerprint: String) {
        self.host = host
        self.fingerprint = fingerprint
    }
}

/// Lists the folders in `path` on `host` (~ is the host's home), read over the host's shared SSH connection. It returns
/// the folder's full path there, whether it is in a git repository, and its subfolders (without hidden ones), each
/// marked when it is a repository. A host Kelp can't reach makes this fail with ssh's reason.
public struct RemoteListFolders: InternalMethod {
    public static let name = "remote.listFolders"
    public struct Folder: Codable, Sendable, Equatable {
        public var name: String, git: Bool
        public init(name: String, git: Bool) {
            self.name = name
            self.git = git
        }
    }
    public struct Result: Codable, Sendable {
        public var path: String, repo: Bool, folders: [Folder]
        public init(path: String, repo: Bool, folders: [Folder]) {
            self.path = path
            self.repo = repo
            self.folders = folders
        }
    }
    public var host: String, path: String
    public init(host: String, path: String) {
        self.host = host
        self.path = path
    }
}
