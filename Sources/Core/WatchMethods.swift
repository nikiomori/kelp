import Foundation

// Watching instead of asking again and again: a client says what it shows (`watch.start`), the daemon reads it while
// anyone watches — once for all of them — and pushes it as an event when it changed.

/// What can be watched, and what its key names.
public enum WatchTopic: String, Codable, Sendable, CaseIterable {
    /// A workspace's status, branches and line counts (`GitEvent`): read when its files change. Key: worktree id.
    case git
    /// What a workspace's terminals and agents listen on (`PortsEvent`). Key: worktree id.
    case ports
    /// CPU and memory of every live session (`ActivityEvent`). No key.
    case activity
    /// The branch's CI runs (`CIEvent`): read again while one runs. Key: worktree id.
    case ci
    /// The branch's pull request (`PREvent`). Key: worktree id.
    case pr
    /// How full an agent's conversation is (`ContextEvent`): read while it works and when its status changes. Key: session id.
    case context
    /// The agents' plan limits and token use (`LimitsEvent`). No key.
    case limits
    /// The commands an agent ran (`CommandsEvent`): read when one starts or ends. Key: session id.
    case commands
    /// A file's version (`FileEvent`): read when its folder's files change. Key: its absolute path. A file in a remote
    /// project isn't watched (nothing is pushed).
    case file
    /// A workspace's files (`FilesEvent`, `files.list` and `files.ignored`'s answers): read when its files change, a remote one's every 10 s.
    /// Key: worktree id.
    case files
}

/// Starts watching for this connection: the last value comes at once (the first when it's read), then each change. Watching
/// what this connection watches already reads it again now (after a push: the CI run it started shows within seconds).
public struct WatchStart: RPCMethod, Hashable {
    public static let name = "watch.start"; public typealias Result = Done
    public var topic: WatchTopic, key: String
    public init(_ topic: WatchTopic, _ key: String = "") { self.topic = topic; self.key = key }
}

/// Stops it; a connection that goes away stops all of its own.
public struct WatchStop: RPCMethod {
    public static let name = "watch.stop"; public typealias Result = Done
    public var topic: WatchTopic, key: String
    public init(_ topic: WatchTopic, _ key: String = "") { self.topic = topic; self.key = key }
}

/// A watched workspace's git, read again after its files changed. `error`: git couldn't say (not a repository…).
public struct GitEvent: RPCEvent, Equatable {
    public static let name = "event.git"
    public var worktree: String
    public var changes: [FileChange]?, branches: BranchInfo?, stats: LineStats?, error: String?
    public init(worktree: String, changes: [FileChange]? = nil, branches: BranchInfo? = nil, stats: LineStats? = nil, error: String? = nil) {
        self.worktree = worktree; self.changes = changes; self.branches = branches; self.stats = stats; self.error = error
    }
}

public struct PortsEvent: RPCEvent, Equatable {
    public static let name = "event.ports"
    public var worktree: String, ports: [PortsList.Port]
    public init(worktree: String, ports: [PortsList.Port]) { self.worktree = worktree; self.ports = ports }
}

public struct ActivityEvent: RPCEvent, Equatable {
    public static let name = "event.activity"
    public var usage: [SessionUsage.Usage]?, error: String?
    public init(usage: [SessionUsage.Usage]? = nil, error: String? = nil) { self.usage = usage; self.error = error }
}

public struct CIEvent: RPCEvent, Equatable {
    public static let name = "event.ci"
    public var worktree: String, result: CIRunsList.Result?, error: String?
    public init(worktree: String, result: CIRunsList.Result? = nil, error: String? = nil) { self.worktree = worktree; self.result = result; self.error = error }
}

public struct PREvent: RPCEvent, Equatable {
    public static let name = "event.pr"
    public var worktree: String, pr: GitHub.PullRequest?
    public init(worktree: String, pr: GitHub.PullRequest?) { self.worktree = worktree; self.pr = pr }
}

/// Nil usage: not known (not Claude Code, ended, just compacted).
public struct ContextEvent: RPCEvent, Equatable {
    public static let name = "event.context"
    public var session: String, usage: SessionContextWindow.Usage?
    public init(session: String, usage: SessionContextWindow.Usage?) { self.session = session; self.usage = usage }
}

public struct CommandsEvent: RPCEvent, Equatable {
    public static let name = "event.commands"
    public var session: String, commands: [AgentCommand]
    public init(session: String, commands: [AgentCommand]) { self.session = session; self.commands = commands }
}

public struct LimitsEvent: RPCEvent, Equatable {
    public static let name = "event.limits"
    public var usage: UsageGet.Result
    public init(usage: UsageGet.Result) { self.usage = usage }
}

/// A watched file's version now: the stamp `files.read` and `files.write` give (nil: it's gone, or isn't a file). Only
/// the stamp: whoever holds that version (the app's own save) has nothing to read. A touch is a new version too.
public struct FileEvent: RPCEvent, Equatable {
    public static let name = "event.file"
    public var path: String, stamp: FileStamp?
    public init(path: String, stamp: FileStamp?) { self.path = path; self.stamp = stamp }
}

/// A watched workspace's files as `files.list` gives them, and what git ignores (`files.ignored`), pushed when that
/// changed. `error`: they couldn't be listed.
public struct FilesEvent: RPCEvent, Equatable {
    public static let name = "event.files"
    public var worktree: String, paths: [String]?, ignored: [String]?, error: String?
    public init(worktree: String, paths: [String]? = nil, ignored: [String]? = nil, error: String? = nil) {
        self.worktree = worktree; self.paths = paths; self.ignored = ignored; self.error = error
    }
}

/// A project or workspace record as it is now, after any change (as `event.session` is for sessions).
extension Repo: RPCEvent { public static let name = "event.repo" }
extension Worktree: RPCEvent { public static let name = "event.worktree" }

/// A project, workspace or session record that's gone (a project takes its workspaces with it; their sessions each say so).
public struct RemovedEvent: RPCEvent, Equatable {
    public static let name = "event.removed"
    public var repo: String?, worktree: String?, session: String?
    public init(repo: String? = nil, worktree: String? = nil, session: String? = nil) { self.repo = repo; self.worktree = worktree; self.session = session }
}
