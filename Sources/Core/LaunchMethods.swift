import Foundation

/// How a session starts: the same optional fields on every method that starts one.
public protocol LaunchOptions {
    var model: String? { get }
    var effort: String? { get }
    var prompt: String? { get }
    var title: String? { get }
    var profile: String? { get }
    /// Type the prompt, don't send it.
    var draft: Bool? { get }
    /// The first local URL it prints opens in the workspace's browser (event.devserver).
    var openURLs: Bool? { get }
    var cols: Int? { get }
    var rows: Int? { get }
}

/// A session in `worktreeId`'s folder, or in `cwd` (which wins): agent `agent`, else the shell command `command`;
/// `tmux`: a terminal attached to that tmux session, started if there is none (see `Tmux`).
public struct SessionCreate: RPCMethod, LaunchOptions {
    public static let name = "session.create"; public typealias Result = Session
    public var cwd: String?, worktreeId: String?, agent: String?, command: String?, tmux: String?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
    public init(cwd: String? = nil, worktreeId: String? = nil, agent: String? = nil, command: String? = nil, tmux: String? = nil,
                model: String? = nil, effort: String? = nil, prompt: String? = nil, title: String? = nil, profile: String? = nil, draft: Bool? = nil,
                openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.cwd = cwd; self.worktreeId = worktreeId; self.agent = agent; self.command = command; self.tmux = tmux
        self.model = model; self.effort = effort; self.prompt = prompt; self.title = title; self.profile = profile; self.draft = draft
        self.openURLs = openURLs; self.cols = cols; self.rows = rows
    }
}

/// The tmux sessions on the workspace's machine (a remote project's host), the last used first; none while tmux runs
/// no server there.
public struct TmuxList: RPCMethod {
    public static let name = "tmux.list"; public typealias Result = [Tmux.Session]
    public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
}

/// The same command in the same folder, resuming its conversation unless `resume` is false.
public struct SessionRestart: RPCMethod, LaunchOptions {
    public static let name = "session.restart"; public typealias Result = Session
    public var id: String, resume: Bool?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
    public init(id: String, resume: Bool? = nil, model: String? = nil, effort: String? = nil, prompt: String? = nil, title: String? = nil,
                profile: String? = nil, draft: Bool? = nil, openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.id = id; self.resume = resume
        self.model = model; self.effort = effort; self.prompt = prompt; self.title = title; self.profile = profile; self.draft = draft
        self.openURLs = openURLs; self.cols = cols; self.rows = rows
    }
}

/// A new agent (`agent`, else the same) in the same workspace, briefed with this one's transcript (`full`: all of it).
public struct SessionHandoff: RPCMethod, LaunchOptions {
    public static let name = "session.handoff"; public typealias Result = Session
    public var id: String, agent: String?, full: Bool?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
    public init(id: String, agent: String? = nil, full: Bool? = nil,
                model: String? = nil, effort: String? = nil, prompt: String? = nil, title: String? = nil, profile: String? = nil, draft: Bool? = nil,
                openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.id = id; self.agent = agent; self.full = full
        self.model = model; self.effort = effort; self.prompt = prompt; self.title = title; self.profile = profile; self.draft = draft
        self.openURLs = openURLs; self.cols = cols; self.rows = rows
    }
}

/// An issue or task → a branch with its number, a worktree, an agent briefed with its text → {worktree, session, setupNeedsTrust}.
/// (`title` is the issue's: the session's is "ref title".) The brief is typed, not sent, unless `draft` is false: the issue's
/// text is whoever filed it.
public struct TaskFromIssue: RPCMethod {
    public static let name = "task.fromIssue"
    public struct Result: Codable, Sendable, Equatable {
        public var worktree: Worktree, session: Session
        /// The project's .kelp.yaml has a setup that didn't run: it isn't trusted yet.
        public var setupNeedsTrust: Bool
        public init(worktree: Worktree, session: Session, setupNeedsTrust: Bool) {
            self.worktree = worktree; self.session = session; self.setupNeedsTrust = setupNeedsTrust
        }
    }
    public var repoId: String, ref: String, title: String, body: String?, url: String?, branch: String?, branchPrefix: String?
    public var linearId: String?, agent: String?, prompt: String?
    public var model: String?, effort: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
}

/// A past conversation (`session`, as history.list gives it) as a live session, in `worktreeId` or its own folder.
public struct HistoryResume: RPCMethod, LaunchOptions {
    public static let name = "history.resume"; public typealias Result = Session
    public var session: AgentSessionInfo?, worktreeId: String?
    public var model: String?, effort: String?, prompt: String?, title: String?, profile: String?, draft: Bool?, openURLs: Bool?, cols: Int?, rows: Int?
    public init(session: AgentSessionInfo?, worktreeId: String? = nil,
                model: String? = nil, effort: String? = nil, prompt: String? = nil, title: String? = nil, profile: String? = nil, draft: Bool? = nil,
                openURLs: Bool? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.session = session; self.worktreeId = worktreeId
        self.model = model; self.effort = effort; self.prompt = prompt; self.title = title; self.profile = profile; self.draft = draft
        self.openURLs = openURLs; self.cols = cols; self.rows = rows
    }
}

/// From a running agent's hooks (`kelp hook`): `event`, and what Claude Code's hook payload says.
public struct SessionHook: RPCMethod {
    public static let name = "session.hook"; public typealias Result = Done
    public var id: String, event: String?, transcript: String?, cwd: String?, trigger: String?, notification: JSONValue?
    public var backgroundTasks: [JSONValue]?
    /// `command`: what its shell tool started or finished.
    public var command: AgentCommand?
    enum CodingKeys: String, CodingKey { case id, event, transcript, cwd, trigger, notification, command, backgroundTasks = "background_tasks" }
    public init(id: String, event: String?, transcript: String? = nil, cwd: String? = nil, trigger: String? = nil, notification: JSONValue? = nil,
                backgroundTasks: [JSONValue]? = nil, command: AgentCommand? = nil) {
        self.id = id; self.event = event; self.transcript = transcript; self.cwd = cwd; self.trigger = trigger
        self.notification = notification; self.backgroundTasks = backgroundTasks; self.command = command
    }
}

/// A summary from the UI (the agent's own last reply), and optionally a better status guess.
public struct SessionAnnotate: RPCMethod {
    public static let name = "session.annotate"; public typealias Result = Done; public var id: String, summary: String?, status: String?
    public init(id: String, summary: String? = nil, status: String? = nil) { self.id = id; self.summary = summary; self.status = status }
}
/// The prompt for action `name` in workspace `id`, the project's own wording if it has one (and is trusted).
public struct RecipeRender: RPCMethod {
    public static let name = "recipe.render"; public typealias Result = String; public var id: String, name: String, vars: [String: String]?
    public init(id: String, name: String, vars: [String: String]? = nil) { self.id = id; self.name = name; self.vars = vars }
}
/// The agents on this Mac and their versions.
public struct AgentsVersions: RPCMethod {
    public static let name = "agents.versions"; public typealias Result = [Item]
    public struct Item: Codable, Sendable, Equatable {
        /// nil: not found, or it printed no version (`latest`: not on npm, or npm isn't installed).
        public var id: String, version: String?, latest: String?
        public init(id: String, version: String?, latest: String?) { self.id = id; self.version = version; self.latest = latest }
    }
    public init() {}
}
/// A program run for the app, answered with what it printed: an extension's command (`/bin/zsh -lc …`, values already
/// in as variables by `ShellTemplate`), a formatter, a notebook run, an agent's `--version`. The daemon starts every
/// process; the app starts none. Login-shell PATH, `cwd` (the home folder when it's gone), `stdin`, and `timeLimit`
/// after which it's stopped with everything it started. `extensionId`: an extension's folder in ~/.kelp/extensions —
/// refused once that extension is off or gone.
public struct ProcessRun: RPCMethod {
    public static let name = "process.run"
    /// The run's own limit ends it, and the daemon answers then: a notebook may compute for hours.
    public static var timeout: TimeInterval? { nil }
    public struct Result: Codable, Sendable, Equatable {
        public var code: Int32, stdout: String, stderr: String, timedOut: Bool
        public init(code: Int32, stdout: String, stderr: String, timedOut: Bool) {
            self.code = code; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
        }
    }
    public var argv: [String], cwd: String?, stdin: String?, timeLimit: Double?, extensionId: String?
    public init(argv: [String], cwd: String? = nil, stdin: String? = nil, timeLimit: Double? = nil, extensionId: String? = nil) {
        self.argv = argv; self.cwd = cwd; self.stdin = stdin; self.timeLimit = timeLimit; self.extensionId = extensionId
    }
}
/// Where each command is on the login-shell PATH the daemon gives programs (`process.run`, sessions): command → absolute
/// path, the ones not found left out. The app asks instead of reading that PATH itself, which starts the user's shell.
public struct ProcessWhich: RPCMethod {
    public static let name = "process.which"; public typealias Result = [String: String]
    public var commands: [String]
    public init(commands: [String]) { self.commands = commands }
}
/// The login shell's PATH read again, after an installer changed the shell profile: `process.which` and new sessions
/// then find what it installed. Answered once the shell has been asked (seconds, with a slow profile).
public struct ProcessRefreshPath: RPCMethod {
    public static let name = "process.refreshPath"; public typealias Result = Done
    public init() {}
}
/// "pong".
public struct Ping: RPCMethod { public static let name = "ping"; public typealias Result = String; public init() {} }
public struct DaemonShutdown: RPCMethod { public static let name = "daemon.shutdown"; public typealias Result = Done; public init() {} }
/// The kelpd binary now at the running one's path (an update put it there) takes over in the same process: running
/// sessions carry on, their programs never stop. Answered first; then every connection drops, and the socket answers
/// again once the new one is up.
public struct DaemonUpgrade: RPCMethod { public static let name = "daemon.upgrade"; public typealias Result = Done; public init() {} }
