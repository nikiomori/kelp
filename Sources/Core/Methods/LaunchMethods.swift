import Foundation

/// A method that starts a terminal at its shown size (`workbench.sized`), so its first screen fits. nil means 120 × 32.
public protocol StartsSized {
    var cols: Int? { get set }
    var rows: Int? { get set }
}

/// How a session starts: the same optional fields on every method that starts one.
public protocol LaunchOptions {
    var model: String? { get }
    var effort: String? { get }
    var prompt: String? { get }
    var title: String? { get }
    var profile: String? { get }
    /// Types the prompt without sending it.
    var draft: Bool? { get }
    /// Opens the first local URL the session prints in the workspace's browser (event.devserver).
    var openURLs: Bool? { get }
    var cols: Int? { get }
    var rows: Int? { get }
}

/// Starts a session in `cwd`, or else the folder of `worktreeId`, running `agent` or else the shell command `command`.
/// `tmux` attaches the terminal to that tmux session, started if missing (see `Tmux`). `parent` is the agent session
/// that started this one, if an agent did (see `Session.parent`, `Session.startedBy`). `env` and `args` go on top of
/// the agent's own (Claude Code on a local model's server, say) and stay the session's (`Session.env`).
public struct SessionCreate: RPCMethod, LaunchOptions, StartsSized {
    public static let name = "session.create"
    public typealias Result = Session
    public var cwd: String?, worktreeId: String?, agent: String?, command: String?, tmux: String?, parent: String?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?,
        openURLs: Bool?, cols: Int?, rows: Int?, role: SessionRole?, env: [String: String]?, args: [String]?
    public init(
        cwd: String? = nil, worktreeId: String? = nil, agent: String? = nil, command: String? = nil,
        tmux: String? = nil,
        model: String? = nil, effort: String? = nil, prompt: String? = nil, title: String? = nil,
        profile: String? = nil, draft: Bool? = nil,
        openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil, parent: String? = nil
    ) {
        self.cwd = cwd
        self.worktreeId = worktreeId
        self.agent = agent
        self.command = command
        self.tmux = tmux
        self.parent = parent
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.title = title
        self.profile = profile
        self.draft = draft
        self.openURLs = openURLs
        self.cols = cols
        self.rows = rows
    }
}

/// Lists the tmux sessions on the workspace's machine (a remote project's host), most recently used first. The list is
/// empty while no tmux server runs there.
public struct TmuxList: InternalMethod {
    public static let name = "tmux.list"
    public typealias Result = [Tmux.Session]
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// Restarts the same command in the same folder, resuming its conversation unless `resume` is false.
public struct SessionRestart: RPCMethod, LaunchOptions {
    public static let name = "session.restart"
    public typealias Result = Session
    public var id: String, resume: Bool?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?,
        openURLs: Bool?, cols: Int?, rows: Int?
    public init(
        id: String, resume: Bool? = nil, model: String? = nil, effort: String? = nil, prompt: String? = nil,
        title: String? = nil,
        profile: String? = nil, draft: Bool? = nil, openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil
    ) {
        self.id = id
        self.resume = resume
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.title = title
        self.profile = profile
        self.draft = draft
        self.openURLs = openURLs
        self.cols = cols
        self.rows = rows
    }
}

/// Starts a new chat beside this one, in the same folder, from a copy of its conversation; this chat goes on as it was.
/// Only Claude Code and Codex fork a conversation (`--fork-session`, `codex fork`), so other agents are refused.
public struct SessionFork: RPCMethod {
    public static let name = "session.fork"
    public typealias Result = Session
    public var id: String, cols: Int?, rows: Int?
    public init(id: String, cols: Int? = nil, rows: Int? = nil) {
        self.id = id
        self.cols = cols
        self.rows = rows
    }
}

/// Starts `agent` (or else the same agent) in this workspace, briefed with this transcript (all of it with `full`).
public struct SessionHandoff: RPCMethod, LaunchOptions {
    public static let name = "session.handoff"
    public typealias Result = Session
    public var id: String, agent: String?, full: Bool?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?,
        openURLs: Bool?, cols: Int?, rows: Int?
    public init(
        id: String, agent: String? = nil, full: Bool? = nil,
        model: String? = nil, effort: String? = nil, prompt: String? = nil, title: String? = nil,
        profile: String? = nil, draft: Bool? = nil,
        openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil
    ) {
        self.id = id
        self.agent = agent
        self.full = full
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.title = title
        self.profile = profile
        self.draft = draft
        self.openURLs = openURLs
        self.cols = cols
        self.rows = rows
    }
}

/// Moves a chat to another copy of its project, on a server or on this Mac, as a new chat there. The branch's commits
/// and uncommitted changes go into a new worktree of that copy, and an agent there goes on from a brief of the
/// conversation, as Hand Off does. The chat here is paused, and its folder is left as it is. Returns the new chat.
public struct SessionMoveAcross: InternalMethod {
    public static let name = "session.moveAcross"
    public typealias Result = Session
    public var id: String, repoId: String
    public init(id: String, repoId: String) {
        self.id = id
        self.repoId = repoId
    }
}

/// Starts work on an issue or task: a branch with its number, a worktree, and an agent briefed with the issue's text.
/// The session is titled "ref title". The brief waits unsent unless `draft` is false, as the issue's author wrote it.
public struct TaskFromIssue: RPCMethod {
    public static let name = "task.fromIssue"
    public struct Result: Codable, Sendable, Equatable {
        public var worktree: Worktree, session: Session
        /// True when the project's .kelp.yaml has a setup that didn't run, because it isn't trusted yet.
        public var setupNeedsTrust: Bool
        public init(worktree: Worktree, session: Session, setupNeedsTrust: Bool) {
            self.worktree = worktree
            self.session = session
            self.setupNeedsTrust = setupNeedsTrust
        }
    }
    public var repoId: String, ref: String, title: String, body: String?, url: String?, branch: String?,
        branchPrefix: String?
    public var linearId: String?, agent: String?, prompt: String?
    public var model: String?, effort: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
    public init(
        repoId: String, ref: String, title: String, body: String?, url: String?, linearId: String? = nil,
        agent: String?, draft: Bool? = nil
    ) {
        self.repoId = repoId
        self.ref = ref
        self.title = title
        self.body = body
        self.url = url
        self.linearId = linearId
        self.agent = agent
        self.draft = draft
    }
}

/// Resumes a past conversation (`session`, from history.list) as a live session, in `worktreeId` or its own folder.
public struct HistoryResume: RPCMethod, LaunchOptions {
    public static let name = "history.resume"
    public typealias Result = Session
    public var session: AgentSessionInfo?, worktreeId: String?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?,
        openURLs: Bool?, cols: Int?, rows: Int?
    public init(
        session: AgentSessionInfo?, worktreeId: String? = nil,
        model: String? = nil, effort: String? = nil, prompt: String? = nil, title: String? = nil,
        profile: String? = nil, draft: Bool? = nil,
        openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil
    ) {
        self.session = session
        self.worktreeId = worktreeId
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.title = title
        self.profile = profile
        self.draft = draft
        self.openURLs = openURLs
        self.cols = cols
        self.rows = rows
    }
}

/// Sets a summary from the UI (the agent's last reply), and optionally a better status guess. With `ifStatus`, the
/// call applies only while the session keeps that status, as the row may have moved on to a question.
public struct SessionAnnotate: InternalMethod {
    public static let name = "session.annotate"
    public typealias Result = Done
    public var id: String, summary: String?, status: String?, ifStatus: String?
    public init(id: String, summary: String? = nil, status: String? = nil, ifStatus: String? = nil) {
        self.id = id
        self.summary = summary
        self.status = status
        self.ifStatus = ifStatus
    }
}
/// Returns the prompt for action `name` in workspace `id`, in the project's own wording if it has one and is trusted.
public struct RecipeRender: InternalMethod {
    public static let name = "recipe.render"
    public typealias Result = String
    public var id: String, name: String, vars: [String: String]?
    public init(id: String, name: String, vars: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.vars = vars
    }
}
/// Lists the agents on this Mac and their versions.
public struct AgentsVersions: InternalMethod {
    public static let name = "agents.versions"
    public typealias Result = [Item]
    public struct Item: Codable, Sendable, Equatable {
        /// `version` is nil when the agent wasn't found or printed no version. `latest` is nil when it isn't on npm, or
        /// npm isn't installed.
        public var id: String, version: String?, latest: String?
        public init(id: String, version: String?, latest: String?) {
            self.id = id
            self.version = version
            self.latest = latest
        }
    }
    public init() {}
}
/// Runs a program for the app and answers with what it printed. Examples are an extension's command (`/bin/zsh -lc …`,
/// with values passed as variables by `ShellTemplate`), a formatter, a notebook run, or an agent's `--version`. The
/// daemon starts every process, and the app starts none. The program gets the login-shell PATH, `cwd` (the home folder
/// when `cwd` is gone) and `stdin`. After `timeLimit` it is stopped with everything it started. `extensionId` names an
/// extension's folder in ~/.kelp/extensions, and the call is refused once that extension is off or gone.
public struct ProcessRun: InternalMethod {
    public static let name = "process.run"
    /// No call timeout: the run's own limit ends it and the daemon answers then. A notebook may compute for hours.
    public static var timeout: TimeInterval? { nil }
    public struct Result: Codable, Sendable, Equatable {
        public var code: Int32, stdout: String, stderr: String, timedOut: Bool
        public init(code: Int32, stdout: String, stderr: String, timedOut: Bool) {
            self.code = code
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }
    }
    public var argv: [String], cwd: String?, stdin: String?, timeLimit: Double?, extensionId: String?
    public init(
        argv: [String], cwd: String? = nil, stdin: String? = nil, timeLimit: Double? = nil, extensionId: String? = nil
    ) {
        self.argv = argv
        self.cwd = cwd
        self.stdin = stdin
        self.timeLimit = timeLimit
        self.extensionId = extensionId
    }
}
/// Finds commands on the login-shell PATH the daemon gives programs (`process.run`, sessions), as command → absolute
/// path, leaving out missing ones. The app asks the daemon because reading that PATH would start the user's shell.
public struct ProcessWhich: InternalMethod {
    public static let name = "process.which"
    public typealias Result = [String: String]
    public var commands: [String]
    public init(commands: [String]) { self.commands = commands }
}
/// Reads the login shell's PATH again after an installer changed the profile, so `process.which` and new sessions find
/// what it installed. The daemon answers once the shell has been asked, which takes seconds with a slow profile.
public struct ProcessRefreshPath: InternalMethod {
    public static let name = "process.refreshPath"
    public typealias Result = Done
    public init() {}
}
/// Answers "pong".
public struct Ping: RPCMethod {
    public static let name = "ping"
    public typealias Result = String
    public init() {}
}
/// Stops the daemon, and the agents with it.
public struct DaemonShutdown: InternalMethod {
    public static let name = "daemon.shutdown"
    public typealias Result = Done
    public init() {}
}
/// Makes the kelpd binary now at the running daemon's path (an update put it there) take over in the same process.
/// Running sessions carry on, and their programs never stop. The daemon answers first, then every connection drops, and
/// the socket answers again once the new kelpd is up.
public struct DaemonUpgrade: InternalMethod {
    public static let name = "daemon.upgrade"
    public typealias Result = Done
    public init() {}
}

/// Describes the running daemon. The app compares it with the kelpd it ships, to spot a stale daemon after an update.
public struct DaemonInfo: InternalMethod {
    public static let name = "daemon.info"
    /// This is the first call made to a kelpd, so a stuck one is noticed here and not after minutes of an empty window.
    public static var timeout: TimeInterval? { 10 }
    public struct Result: Codable, Sendable {
        public var path: String, binaryMTime: Double?, pid: Int, liveSessions: Int   // binaryMTime since 2026-10-19
        public init(path: String, binaryMTime: Double?, pid: Int, liveSessions: Int) {
            self.path = path
            self.binaryMTime = binaryMTime
            self.pid = pid
            self.liveSessions = liveSessions
        }
    }
    public init() {}
}

/// Returns false when Kelp's switch in Login Items is off, because macOS then ends the daemon and its agents with the
/// app. The daemon answers, not the CLI: a `kelp` linked onto the PATH can't tell its app, while kelpd runs inside it.
public struct DaemonBackgroundAllowed: InternalMethod {
    public static let name = "daemon.backgroundAllowed"
    public typealias Result = Bool
    public init() {}
}

/// Sets whether this connection wants the daemon's broadcast events. The control connection of `kelp attach` only sends
/// sizes, and without this every open terminal would be one more reader of every event.
public struct ClientEvents: InternalMethod {
    public static let name = "client.events"
    public typealias Result = Done
    public var events: Bool
    public init(events: Bool) { self.events = events }
}
