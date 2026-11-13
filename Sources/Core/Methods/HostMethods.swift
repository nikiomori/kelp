import Foundation

/// How a remote projects' host is doing, read in one call over its shared connection: what htop shows, plus which of its
/// processes are Kelp's agents. `connect` false (the sidebar's look every few seconds) never dials: without an open
/// connection the answer is only `connected` false and why the last try failed.
public struct HostStatsRead: InternalMethod {
    public static let name = "host.stats"
    public typealias Result = HostStats
    public var host: String, connect: Bool?
    public init(host: String, connect: Bool? = nil) {
        self.host = host
        self.connect = connect
    }
}

/// The host's readings of the last hour, oldest first: what the daemon read while its server was listed (every 10 s)
/// or on screen (every 2 s). Empty for a host it hasn't read since it started.
public struct HostHistoryRead: InternalMethod {
    public static let name = "host.history"
    public typealias Result = [HostStats.Sample]
    public var host: String
    public init(host: String) { self.host = host }
}

/// Closes the host's shared connection (`ssh -O exit`): agents in tmux there go on.
public struct HostDisconnect: InternalMethod {
    public static let name = "host.disconnect"
    public typealias Result = Done
    public var host: String
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
    /// Of that moment, the share spent waiting on the disk, and the share the machine under a VM took (steal), 0–100.
    /// Linux only.
    public var iowait: Double?, steal: Double?
    /// Bytes a second in and out on the interface the default route takes, over the same moment. Linux only.
    public var network: Network?
    /// Bytes used and in all. Memory and swap: Linux only.
    public var memory: Int?, memoryTotal: Int?, swap: Int?, swapTotal: Int?, disk: Int?, diskTotal: Int?
    public var processCount: Int?
    /// The busiest processes, and every one of Kelp's agents, by CPU.
    public var processes: [Process]?
    /// TCP ports something listens on.
    public var ports: [Port]?
    /// Kelp's tmux sessions there (`Tmux.isOwn`), with the Kelp session each belongs to, if one does.
    public var tmux: [TmuxSession]?
    /// The Docker containers running, when the user may ask docker.
    public var containers: [Container]?
    /// systemd units that failed ("nginx.service"). Linux with systemd only.
    public var failedUnits: [String]?
    /// The system asks for a restart (Debian and Ubuntu, after an update that needs one).
    public var rebootRequired: Bool?

    public init(host: String, connected: Bool, error: String? = nil) {
        self.host = host
        self.connected = connected
        self.error = error
    }

    public struct Process: Codable, Sendable, Equatable {
        public var pid: Int, user: String, cpu: Double
        /// Resident bytes; seconds it has run.
        public var memory: Int, seconds: Int
        /// The program's name, and its whole command line.
        public var command: String, args: String
        /// The Kelp session it runs under (its tmux pane's), if any.
        public var session: String?
        /// The systemd unit it runs in ("nginx.service", "session-4.scope"), and the Docker container, by name. Linux only.
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
        /// Reached only from the server itself (127.0.0.1, ::1): forward it to use it here.
        public var local: Bool
        /// What listens: the program (`ss` tells only for the user's own), and the Docker container it's published from.
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
        /// Bytes a second.
        public var received: Double, sent: Double
        public init(interface: String, received: Double, sent: Double) {
            self.interface = interface
            self.received = received
            self.sent = sent
        }
    }

    public struct Container: Codable, Sendable, Equatable {
        public var name: String
        /// The host's ports it's published on.
        public var ports: [Int]
        /// What its processes take together, and how long its oldest has run; nil when ps can't tell whose they are.
        public var cpu: Double?, memory: Int?, seconds: Int?
        public init(name: String, ports: [Int], cpu: Double? = nil, memory: Int? = nil, seconds: Int? = nil) {
            self.name = name
            self.ports = ports
            self.cpu = cpu
            self.memory = memory
            self.seconds = seconds
        }
    }

    /// One reading, for the history: when (seconds since 1970), the CPU and memory shares 0–1, the network's bytes a second.
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
    /// What wants you now (the app says "Disk 92%"), nil while all's well: a disk or memory over 90 %, or every core busy for
    /// about a minute (the CPU now and the minute's load both high), worst first.
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

/// The key a host Kelp hasn't connected to before presents (ssh refused it: "Host key verification failed"), as ssh
/// shows one: "SHA256:…" and its kind (ED25519). Asked of the host where ~/.ssh/config sends `host`; nil when it can't
/// be (a jump host in between, no answer).
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

/// Trusts `host`'s key, as answering ssh's "yes" does: asked of it again, and kept in ~/.ssh/known_hosts only when it's
/// still the one shown (`fingerprint`).
public struct RemoteTrustHost: InternalMethod {
    public static let name = "remote.trustHost"
    public typealias Result = Done
    public var host: String, fingerprint: String
    public init(host: String, fingerprint: String) {
        self.host = host
        self.fingerprint = fingerprint
    }
}

/// The folders in `path` on `host` (~ is the host's home), over the host's shared SSH connection: the folder's full
/// path there, whether it's in a git repository, and its subfolders, hidden ones left out, each marked when it's a
/// repository. A host Kelp can't reach fails here, with ssh's reason.
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
