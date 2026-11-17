import Foundation

// The ports.* methods: the ports a workspace's sessions listen on, stopping a listener, and forwarding a remote host's
// ports to this Mac.

/// Lists the ports the workspace's sessions listen on.
public struct PortsList: RPCMethod {
    public static let name = "ports.list"
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
    /// A port that a process of one of the workspace's sessions listens on. On a remote project's host, it is a process
    /// in the project's folder.
    public struct Port: Codable, Sendable, Equatable {
        /// `session` is "" when it can't be told. `pid` is 0 when there is no process, for a forwarding asked for by
        /// hand.
        public var port: Int, pid: Int32, command: String, session: String
        /// For a remote project, the host, the port on this Mac once forwarded, and true when the host can't be asked
        /// (so this is its last answer).
        public var host: String?, here: Int?, offline: Bool?
        public init(
            port: Int, pid: Int32, command: String, session: String, host: String? = nil, here: Int? = nil,
            offline: Bool? = nil
        ) {
            self.port = port
            self.pid = pid
            self.command = command
            self.session = session
            self.host = host
            self.here = here
            self.offline = offline
        }
    }
    public typealias Result = [Port]
}
/// Stops the process listening on a port. Only a process that one of the workspace's sessions started can be
/// stopped.
public struct PortsStop: RPCMethod {
    public static let name = "ports.stop"
    public typealias Result = Done
    public var worktreeId: String, pid: Int?
    public init(worktreeId: String, pid: Int?) {
        self.worktreeId = worktreeId
        self.pid = pid
    }
}
/// Forwards a port of a remote project's host to this Mac: `port` as listed, or `target` ("5432",
/// "db.internal:5432"). It connects when the connection is gone.
public struct PortsForward: InternalMethod {
    public static let name = "ports.forward"
    public var worktreeId: String, port: Int?, target: String?
    public init(worktreeId: String, port: Int? = nil, target: String? = nil) {
        self.worktreeId = worktreeId
        self.port = port
        self.target = target
    }
    public struct Forwarded: Codable, Sendable, Equatable {
        /// The port on this Mac.
        public var port: Int
        public init(port: Int) { self.port = port }
    }
    public typealias Result = Forwarded
}
public struct PortsUnforward: InternalMethod {
    public static let name = "ports.unforward"
    public typealias Result = Done
    public var worktreeId: String, port: Int
    public init(worktreeId: String, port: Int) {
        self.worktreeId = worktreeId
        self.port = port
    }
}
