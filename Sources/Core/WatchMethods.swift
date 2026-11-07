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
    /// What an agent's subagents at work did last (`SubagentsEvent`): read every few seconds while someone looks. Key: session id.
    case subagents
    /// A file's version (`FileEvent`): read when its folder's files change. Key: its absolute path. A file in a remote
    /// project isn't watched (nothing is pushed).
    case file
    /// A workspace's files (`FilesEvent`, `files.list` and `files.ignored`'s answers): read when its files change, a remote one's every 10 s.
    /// Key: worktree id.
    case files
    /// How a remote host is doing (`HostEvent`): read every 10 s while watched (the sidebar's heading), never dialing: without
    /// an open connection only that it's off. Key: the host.
    case host
    /// The same every 2 s, for the server tab on screen. Key: the host.
    case hostDetail
    /// Kelp's virtual machines (`MachinesEvent`): read every 5 s while watched, every second while one starts or is made.
    /// No key.
    case machines
    /// What runs in one machine (`MachineEvent`): every 2 s, for its tab on screen. Reading never wakes it. Key: its name.
    case machineDetail
    /// The pages agents made in a workspace (`ArtifactsEvent`): read when its `.kelp/artifacts` changes. Nothing for a
    /// remote project. Key: worktree id.
    case artifacts
}

/// Starts watching for this connection: the last value comes at once (the first when it's read), then each change. Watching
/// what this connection watches already reads it again now (after a push: the CI run it started shows within seconds).
public struct WatchStart: InternalMethod, Hashable {
    public static let name = "watch.start"; public typealias Result = Done
    public var topic: WatchTopic, key: String
    public init(_ topic: WatchTopic, _ key: String = "") { self.topic = topic; self.key = key }
}

/// Stops it; a connection that goes away stops all of its own.
public struct WatchStop: InternalMethod {
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

public struct SubagentsEvent: RPCEvent, Equatable {
    public static let name = "event.subagents"
    public var session: String, steps: SessionSubagentSteps.Result
    public init(session: String, steps: SessionSubagentSteps.Result) { self.session = session; self.steps = steps }
}

public struct HostEvent: RPCEvent, Equatable {
    public static let name = "event.host"
    public var stats: HostStats
    public init(stats: HostStats) { self.stats = stats }
}

public struct MachinesEvent: RPCEvent, Equatable {
    public static let name = "event.machines"
    public var machines: [VMInfo]
    public init(machines: [VMInfo]) { self.machines = machines }
}

/// What runs in a machine; nil while it isn't running.
public struct MachineEvent: RPCEvent, Equatable {
    public static let name = "event.machine"
    public var name: String, detail: VMDetail?
    public init(name: String, detail: VMDetail?) { self.name = name; self.detail = detail }
}

public struct LimitsEvent: RPCEvent, Equatable {
    public static let name = "event.limits"
    public var usage: UsageGet.Result
    public init(usage: UsageGet.Result) { self.usage = usage }
}

/// A watched file's version now: the stamp `files.read` and `files.write` give (nil: it's gone, or isn't a file). Only
/// the stamp: whoever holds that version (the app's own save) has nothing to read. A touch is a new version too.
/// `problems`: what its language server says is wrong with it, pushed as the server says it.
public struct FileEvent: RPCEvent, Equatable {
    public static let name = "event.file"
    public var path: String, stamp: FileStamp?, problems: [CodeProblem]?
    public init(path: String, stamp: FileStamp?, problems: [CodeProblem]? = nil) { self.path = path; self.stamp = stamp; self.problems = problems }
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

/// A watched workspace's artifacts (`.kelp/artifacts`), newest first, pushed when that folder changed.
public struct ArtifactsEvent: RPCEvent, Equatable {
    public static let name = "event.artifacts"
    public var worktree: String, items: [ArtifactItem]
    public init(worktree: String, items: [ArtifactItem]) { self.worktree = worktree; self.items = items }
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

/// What the daemon pushes for a watched topic, as the app keeps it: the latest by `key` (a workspace, a session, a path;
/// "" for one of a kind). A new kind is declared here, with its event, and touches no file of the app's shell.
public protocol Pushed: RPCEvent, Equatable {
    var key: String { get }
    /// The topic whose last watcher letting go drops it, so it isn't shown stale when watched again; nil: kept (another
    /// may still watch it, and an old value says only how it was).
    static var forgottenWith: WatchTopic? { get }
    /// Whether it takes `old`'s place: each change re-renders its readers.
    func replaces(_ old: Self?) -> Bool
}

extension Pushed {
    public func replaces(_ old: Self?) -> Bool { old != self }
}

extension GitEvent: Pushed { public var key: String { worktree }; public static var forgottenWith: WatchTopic? { .git } }
extension PortsEvent: Pushed { public var key: String { worktree }; public static var forgottenWith: WatchTopic? { .ports } }
extension ActivityEvent: Pushed { public var key: String { "" }; public static var forgottenWith: WatchTopic? { .activity } }
extension CIEvent: Pushed { public var key: String { worktree }; public static var forgottenWith: WatchTopic? { .ci } }
extension PREvent: Pushed { public var key: String { worktree }; public static var forgottenWith: WatchTopic? { .pr } }
extension LimitsEvent: Pushed { public var key: String { "" }; public static var forgottenWith: WatchTopic? { .limits } }
extension FileEvent: Pushed { public var key: String { path }; public static var forgottenWith: WatchTopic? { .file } }
extension FilesEvent: Pushed { public var key: String { worktree }; public static var forgottenWith: WatchTopic? { .files } }
extension ArtifactsEvent: Pushed { public var key: String { worktree }; public static var forgottenWith: WatchTopic? { .artifacts } }
extension CommandsEvent: Pushed { public var key: String { session }; public static var forgottenWith: WatchTopic? { .commands } }
extension SubagentsEvent: Pushed { public var key: String { session }; public static var forgottenWith: WatchTopic? { .subagents } }
extension RoutinesEvent: Pushed { public var key: String { "" }; public static var forgottenWith: WatchTopic? { nil } }   // always pushed
extension HostEvent: Pushed { public var key: String { stats.host }; public static var forgottenWith: WatchTopic? { nil } }
extension MachinesEvent: Pushed { public var key: String { "" }; public static var forgottenWith: WatchTopic? { nil } }
extension MachineEvent: Pushed { public var key: String { name }; public static var forgottenWith: WatchTopic? { .machineDetail } }
extension ContextEvent: Pushed {
    public var key: String { session }
    public static var forgottenWith: WatchTopic? { .context }
    /// The ring's usage: none (not Claude Code, ended, just compacted) takes the ring away.
    public var shown: SessionContextWindow.Usage? { usage.flatMap { $0.window > 0 ? $0 : nil } }
    /// A percent at a time: a ring redrawn for every token would re-render each reader.
    public func replaces(_ old: ContextEvent?) -> Bool {
        func share(_ u: SessionContextWindow.Usage?) -> Double { u.map { Double($0.used) / Double($0.window) } ?? -1 }
        return shown?.window != old?.shown?.window || abs(share(shown) - share(old?.shown)) > 0.01
    }
}
