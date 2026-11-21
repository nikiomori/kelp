import Foundation

// Watching replaces asking again and again. A client says what it shows (`watch.start`). While anyone watches, the
// daemon reads it once for all watchers and pushes it as an event when it changes.

/// The things that can be watched, and what each one's key names.
public enum WatchTopic: String, Codable, Sendable, CaseIterable {
    /// A workspace's status, branches and line counts (`GitEvent`), read when its files change. Key: worktree id.
    case git
    /// The ports a workspace's terminals and agents listen on (`PortsEvent`). Key: worktree id.
    case ports
    /// The CPU and memory of every live session (`ActivityEvent`). No key.
    case activity
    /// The branch's CI runs (`CIEvent`), read again while a run is going. Key: worktree id.
    case ci
    /// The branch's pull request (`PREvent`). Key: worktree id.
    case pr
    /// How full an agent's conversation is (`ContextEvent`), read while the agent works and when its status changes.
    /// Key: session id.
    case context
    /// The agents' plan limits and token use (`LimitsEvent`). No key.
    case limits
    /// The commands an agent ran (`CommandsEvent`), read when a command starts or ends. Key: session id.
    case commands
    /// What an agent's working subagents did last (`SubagentsEvent`), read every few seconds while someone looks. Key:
    /// session id.
    case subagents
    /// The file an agent's tools changed last (`EditsEvent`), pushed as each edit ends. Key: session id.
    case edits
    /// A file's version (`FileEvent`), read when the files in its folder change. The key is its absolute path. A file
    /// in a remote project isn't watched (nothing is pushed).
    case file
    /// A workspace's files (`FilesEvent`, the answers of `files.list` and `files.ignored`), read when its files change,
    /// or every 10 s for a remote workspace. Key: worktree id.
    case files
    /// How a remote host is doing (`HostEvent`), read every 10 s while watched (by the sidebar's heading). It never
    /// dials, so without an open connection it only says that the host is off. The key is the host.
    case host
    /// The same as `host`, read every 2 s, for the server tab on screen. Key: the host.
    case hostDetail
    /// Kelp's virtual machines (`MachinesEvent`), read every 5 s while watched, and every second while a machine starts
    /// or is being made. No key.
    case machines
    /// What runs in one machine (`MachineEvent`), read every 2 s for its tab on screen. Reading never wakes the
    /// machine. Key: the machine's name.
    case machineDetail
    /// The pages agents made in a workspace (`ArtifactsEvent`), read when its `.kelp/artifacts` changes. Nothing is
    /// pushed for a remote project. Key: worktree id.
    case artifacts
    /// A workspace's databases and what was run on them (`DatabasesEvent`), read when a statement runs, or when a file
    /// that names a database changes. Key: worktree id.
    case databases
    /// The bridge to phones (`PhoneEvent`), read every 2 s while Settings › Phone is shown. No key. Agents may not
    /// watch it.
    case phone
    /// A project's open pull requests (`PRsEvent`), read every 2 minutes while watched. Key: repo id.
    case prs
    /// Where an agent worked (`WorkEvent`): its conversations' sizes, read every 2 s while the Work panel or the Map
    /// tab is on screen. Key: session id.
    case work
}

/// Starts watching for this connection. The last value comes at once (or the first one, once it is read), then each
/// change. Watching something this connection already watches reads it again now, so after a push the CI run it started
/// shows within seconds.
public struct WatchStart: InternalMethod, Hashable {
    public static let name = "watch.start"
    public typealias Result = Done
    public var topic: WatchTopic, key: String
    public init(_ topic: WatchTopic, _ key: String = "") {
        self.topic = topic
        self.key = key
    }
}

/// Stops a watch. A connection that goes away stops all of its own watches.
public struct WatchStop: InternalMethod {
    public static let name = "watch.stop"
    public typealias Result = Done
    public var topic: WatchTopic, key: String
    public init(_ topic: WatchTopic, _ key: String = "") {
        self.topic = topic
        self.key = key
    }
}

/// A watched workspace's git state, read again after its files changed. `error` is set when git couldn't answer (not a
/// repository…).
public struct GitEvent: RPCEvent, Equatable {
    public static let name = "event.git"
    public var worktree: String
    public var changes: [FileChange]?, branches: BranchInfo?, stats: LineStats?, error: String?
    /// The files the branch committed since it left the project's base branch (nil on the base itself). Together with
    /// `changes`, these are all the files it would bring in, which another folder of the project may be changing too.
    public var branchFiles: [String]?
    /// What closing a branch group's folder would lose (nil for other folders). `only` counts the branch's commits that
    /// no other branch or remote has. `dirty` means files aren't committed, by the rule its removal follows (a new link
    /// doesn't count).
    public var only: Int?, dirty: Bool?
    public init(
        worktree: String, changes: [FileChange]? = nil, branches: BranchInfo? = nil, stats: LineStats? = nil,
        error: String? = nil
    ) {
        self.worktree = worktree
        self.changes = changes
        self.branches = branches
        self.stats = stats
        self.error = error
    }
}

public struct PortsEvent: RPCEvent, Equatable {
    public static let name = "event.ports"
    public var worktree: String, ports: [PortsList.Port]
    public init(worktree: String, ports: [PortsList.Port]) {
        self.worktree = worktree
        self.ports = ports
    }
}

public struct ActivityEvent: RPCEvent, Equatable {
    public static let name = "event.activity"
    public var usage: [SessionUsage.Usage]?, error: String?
    public init(usage: [SessionUsage.Usage]? = nil, error: String? = nil) {
        self.usage = usage
        self.error = error
    }
}

public struct CIEvent: RPCEvent, Equatable {
    public static let name = "event.ci"
    public var worktree: String, result: CIRunsList.Result?, error: String?
    public init(worktree: String, result: CIRunsList.Result? = nil, error: String? = nil) {
        self.worktree = worktree
        self.result = result
        self.error = error
    }
}

/// A project's open pull requests, or why they couldn't be read.
public struct PRsEvent: RPCEvent, Equatable {
    public static let name = "event.prs"
    public var repo: String, prs: [GitHub.PullRequest]?, error: String?
    public init(repo: String, prs: [GitHub.PullRequest]? = nil, error: String? = nil) {
        self.repo = repo
        self.prs = prs
        self.error = error
    }
}

public struct PREvent: RPCEvent, Equatable {
    public static let name = "event.pr"
    public var worktree: String, pr: GitHub.PullRequest?
    public init(worktree: String, pr: GitHub.PullRequest?) {
        self.worktree = worktree
        self.pr = pr
    }
}

/// How full a session's conversation is. Nil usage means it isn't known (not Claude Code, ended, or just
/// compacted).
public struct ContextEvent: RPCEvent, Equatable {
    public static let name = "event.context"
    public var session: String, usage: SessionContextWindow.Usage?
    public init(session: String, usage: SessionContextWindow.Usage?) {
        self.session = session
        self.usage = usage
    }
}

public struct CommandsEvent: RPCEvent, Equatable {
    public static let name = "event.commands"
    public var session: String, commands: [AgentCommand]
    public init(session: String, commands: [AgentCommand]) {
        self.session = session
        self.commands = commands
    }
}

/// The file an agent's tools changed last. `count` counts the agent's edits, so the same file edited again is news
/// too.
public struct EditsEvent: RPCEvent, Equatable {
    public static let name = "event.edits"
    public var session: String, path: String?, count: Int
    public init(session: String, path: String?, count: Int) {
        self.session = session
        self.path = path
        self.count = count
    }
}

public struct SubagentsEvent: RPCEvent, Equatable {
    public static let name = "event.subagents"
    public var session: String, steps: SessionSubagentSteps.Result
    public init(session: String, steps: SessionSubagentSteps.Result) {
        self.session = session
        self.steps = steps
    }
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

/// What runs in a machine. nil while the machine isn't running.
public struct MachineEvent: RPCEvent, Equatable {
    public static let name = "event.machine"
    public var name: String, detail: VMDetail?
    public init(name: String, detail: VMDetail?) {
        self.name = name
        self.detail = detail
    }
}

public struct LimitsEvent: RPCEvent, Equatable {
    public static let name = "event.limits"
    public var usage: UsageGet.Result
    public init(usage: UsageGet.Result) { self.usage = usage }
}

/// A watched file's current version, as the stamp that `files.read` and `files.write` give (nil when the file is gone,
/// or isn't a file). Only the stamp is sent, so whoever already holds that version (the app's own save) has nothing to
/// read. A touch is a new version too. `problems` is what the file's language server says is wrong with it, pushed as
/// the server reports it.
public struct FileEvent: RPCEvent, Equatable {
    public static let name = "event.file"
    public var path: String, stamp: FileStamp?, problems: [CodeProblem]?
    public init(path: String, stamp: FileStamp?, problems: [CodeProblem]? = nil) {
        self.path = path
        self.stamp = stamp
        self.problems = problems
    }
}

/// A watched workspace's files as `files.list` gives them, and what git ignores (`files.ignored`), pushed when they
/// changed. `error` is set when the files couldn't be listed.
public struct FilesEvent: RPCEvent, Equatable {
    public static let name = "event.files"
    public var worktree: String, paths: [String]?, ignored: [String]?, error: String?
    public init(worktree: String, paths: [String]? = nil, ignored: [String]? = nil, error: String? = nil) {
        self.worktree = worktree
        self.paths = paths
        self.ignored = ignored
        self.error = error
    }
}

/// A watched workspace's artifacts (`.kelp/artifacts`), most recently changed first, pushed when that folder changed.
public struct ArtifactsEvent: RPCEvent, Equatable {
    public static let name = "event.artifacts"
    public var worktree: String, items: [ArtifactItem]
    /// Why the pages couldn't be read, when they couldn't: there are no items then.
    public var error: String?
    public init(worktree: String, items: [ArtifactItem], error: String? = nil) {
        self.worktree = worktree
        self.items = items
        self.error = error
    }
}

/// A project or workspace record as it is now, after any change (as `event.session` is for sessions).
extension Repo: RPCEvent { public static let name = "event.repo" }
extension Worktree: RPCEvent { public static let name = "event.worktree" }

/// A branch group that closed by itself (`Workspaces.tidyBranch`) because its work is in the base branch now.
/// `archived` means chats were left on it, so it was put away with them (Window › Archived Groups) rather than removed.
public struct LandedEvent: RPCEvent, Equatable {
    public static let name = "event.landed"
    public var worktree: String, name: String, base: String, archived: Bool
    public init(worktree: String, name: String, base: String, archived: Bool) {
        self.worktree = worktree
        self.name = name
        self.base = base
        self.archived = archived
    }
}

/// A project, workspace or session record that is gone. A project takes its workspaces with it, and their sessions each
/// send their own event.
public struct RemovedEvent: RPCEvent, Equatable {
    public static let name = "event.removed"
    public var repo: String?, worktree: String?, session: String?
    public init(repo: String? = nil, worktree: String? = nil, session: String? = nil) {
        self.repo = repo
        self.worktree = worktree
        self.session = session
    }
}
