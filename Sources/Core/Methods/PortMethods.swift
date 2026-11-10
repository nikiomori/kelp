import Foundation

// ports.*: what a workspace's sessions listen on, stopping one, and a remote host's ports brought here.

/// The ports the workspace's sessions listen on.
public struct PortsList: RPCMethod {
    public static let name = "ports.list"
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
    /// A port a process of one of the workspace's sessions listens on; on a remote project's host, one in its folder.
    public struct Port: Codable, Sendable, Equatable {
        /// `session`: "" when it can't be told. `pid` 0: none, a forwarding asked for by hand.
        public var port: Int, pid: Int32, command: String, session: String
        /// On a remote project: its host, the port on this Mac once forwarded, and true when the host can't be asked
        /// (this is its last answer).
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
/// Only a process one of the workspace's sessions started.
public struct PortsStop: RPCMethod {
    public static let name = "ports.stop"
    public typealias Result = Done
    public var worktreeId: String, pid: Int?
    public init(worktreeId: String, pid: Int?) {
        self.worktreeId = worktreeId
        self.pid = pid
    }
}
/// A port of a remote project's host brought to this Mac: `port` as listed, or `target` ("5432", "db.internal:5432").
/// Connects when the connection is gone.
public struct PortsForward: InternalMethod {
    public static let name = "ports.forward"
    public var worktreeId: String, port: Int?, target: String?
    public init(worktreeId: String, port: Int? = nil, target: String? = nil) {
        self.worktreeId = worktreeId
        self.port = port
        self.target = target
    }
    public struct Forwarded: Codable, Sendable, Equatable {
        /// On this Mac.
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
