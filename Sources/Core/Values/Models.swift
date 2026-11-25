import Foundation

/// A record the daemon keeps, such as a project, a workspace or a session. Each write gives the record the next
/// revision. So when two copies disagree (a reply and an event that passed each other, or a list read before a change),
/// the copy with the higher revision is the newer one.
public protocol Revised: Identifiable where ID == String {
    var revision: Int? { get set }
}

extension Revised {
    /// Returns true when this copy is older than `other`, so it holds less than the copy already there. A nil revision
    /// (from a daemon that predates revisions) counts as 0.
    public func isOlder(than other: Self?) -> Bool { (revision ?? 0) < (other?.revision ?? 0) }
}

public struct Repo: Codable, Sendable, Equatable, Revised {
    public var id: String
    public var revision: Int?
    public var name: String
    public var path: String
    public var baseBranch: String
    /// Glob-ish file names copied from the repo into each new worktree (e.g. ".env").
    public var copyFiles: [String]
    public init(
        id: String = UUID().uuidString, name: String, path: String, baseBranch: String = "main",
        copyFiles: [String] = [".env", ".env.local"]
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.baseBranch = baseBranch
        self.copyFiles = copyFiles
    }
}

extension Repo {
    /// The UI state key that lists the projects whose terminals and agents run in their dev container. The value is a
    /// list of project ids, and only Kelp's window sets it (`state.set`).
    public static let devContainerKey = "devcontainer.projects"
    /// The UI state key that maps a project id to the Kelp machine its terminals run in. Only Kelp's window sets it
    /// (`state.set`). The project's agents stay on this Mac and reach the machine with `kelp vm run`.
    public static let machineKey = "machines.projects"
}

public struct Worktree: Codable, Sendable, Equatable, Revised {
    public var id: String
    public var revision: Int?
    public var repoId: String
    public var branch: String
    public var path: String
    public var note: String
    public var archived: Bool
    public var createdAt: Date
    /// Links to the task the workspace came from and the PR it became, such as "#123" or "ENG-123".
    public var issue: String
    public var issueURL: String
    public var linearIssueId: String
    public var prNumber: Int?
    public var prURL: String
    /// The branch this worktree's branch was cut from. When that isn't the repo's base branch, the worktree is part of
    /// a PR stack.
    public var base: String
    /// The session whose program made this workspace (the same kind of id as `Session.origin`). An agent may work in a
    /// workspace it made, even after the daemon restarts. nil means the user made it.
    public var madeBy: String?
    public init(
        id: String = UUID().uuidString, repoId: String, branch: String, path: String, note: String = "",
        archived: Bool = false,
        createdAt: Date = Date(), issue: String = "", issueURL: String = "", linearIssueId: String = "",
        prNumber: Int? = nil, prURL: String = "", base: String = ""
    ) {
        self.base = base
        self.id = id
        self.repoId = repoId
        self.branch = branch
        self.path = path
        self.note = note
        self.archived = archived
        self.createdAt = createdAt
        self.issue = issue
        self.issueURL = issueURL
        self.linearIssueId = linearIssueId
        self.prNumber = prNumber
        self.prURL = prURL
    }
}

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle, working, waiting, done, exited
    /// The session's process was stopped to save memory, and its conversation resumes when it is opened again. The wire
    /// name is "hibernated".
    case paused = "hibernated"
    /// The agent says its turn failed (OSC 7501 "error"). The status stays until the next turn.
    case error
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Needs you"
        case .done: "Done"
        case .exited: "Exited"
        case .paused: "Paused"
        case .error: "Failed"
        }
    }
}

/// A plan limit that stopped a session's turn.
public struct LimitHit: Codable, Sendable, Equatable {
    /// The limit's name as the agent gives it, such as "5-hour", "weekly" or "usage".
    public var kind: String
    /// When the limit resets, as the agent printed it ("3:40pm", "Oct 20 at 5am"). nil when the agent didn't say.
    public var resets: String?
    /// When the limit stopped the turn. `resets` is read relative to this time, so "3pm" still means that day's 3pm
    /// after it has passed.
    public var at: Date
    public init(kind: String, resets: String?, at: Date = Date()) {
        self.kind = kind
        self.resets = resets
        self.at = at
    }
}

/// A subagent that an agent started during its turn, either still at work or finished. `kind` is empty when Kelp only
/// learned of the subagent from a terminal report.
public struct Subagent: Codable, Sendable, Equatable, Identifiable {
    public var id: String, kind: String, task: String?
    public var started: Date
    public var ended: Date?
    /// True while the subagent's permission dialog is open.
    public var asks: Bool?
    public init(id: String, kind: String, task: String?, started: Date = Date()) {
        self.id = id
        self.kind = kind
        self.task = task
        self.started = started
    }
}

public struct Session: Codable, Sendable, Equatable, Revised {
    public var id: String
    public var revision: Int?
    public var worktreeId: String?
    public var cwd: String
    public var command: String
    public var agent: String?
    public var status: AgentStatus {
        didSet {
            guard status != oldValue else { return }
            statusAt = Date()
            if status != .paused { interruptedAt = nil }   // back at work (or ended): no longer cut short
            // A Stop that waits for a subagent keeps the session working. When the turn is cut short, no hook says the
            // subagents ended, so they are cleared here.
            if status != .working && status != .waiting {
                subagents = nil
                subagentTasks = nil
                subagentRuns = nil
            }
        }
    }
    /// When `status` last changed ("working for 4m", "done 2h ago"). nil for sessions older than this field.
    public var statusAt: Date?
    public var unread: Bool
    public var pid: Int32
    public var createdAt: Date
    /// The tab title, taken from the first prompt or set by hand. A name set by hand wins.
    public var title: String
    public var titleManual: Bool
    /// A one-line summary of what the agent did or is asking, from a local model or from hooks.
    public var summary: String
    /// The launch options, kept so "Restart" starts the same session again.
    public var argv: [String]
    /// The folder the agent works in after it leaves `cwd`, as its hooks report it (Claude Code moving into
    /// `.claude/worktrees/…`). nil while the agent works in `cwd`. Kelp reads the paths the agent prints and the
    /// changes of its last turn in this folder, but a restart still starts in `cwd`.
    public var workDir: String?
    /// The git worktree of its project, other than the folder it started in, that the agent last worked in: a branch
    /// of its own that its CLI made (Claude Code's `.claude/worktrees/…`), not one of Kelp's groups. Unlike `workDir`,
    /// it stays when the agent works in its first folder again. The chat's row shows that branch (`branchKey`).
    public var branchFolder: String?
    /// How far the session's program has got, from 0 to 100, when the program reports it (the `progress` field of
    /// OSC 7501, `kelp report`, or ConEmu's OSC 9;4).
    public var progress: Int?
    /// How the session's program ended: the exit code, or 128 plus the signal that stopped it. nil while it runs.
    public var exitCode: Int?
    /// The account profile the session started with (Settings › Accounts). nil means the agent's own default login. It
    /// is kept so that a woken or restarted session comes back on the same account.
    public var profile: String?
    /// The tmux session on a remote project's host that the agent runs in (`RemoteHost.command(_:inTmux:)`), so the
    /// agent outlives a dropped connection and the daemon. It is kept so a wake or a restart attaches to it again. nil
    /// for local sessions, and once Kelp has ended that tmux session (Stop, or closing the tab).
    public var tmux: String?
    /// The current Codex thread reported by a host hook, kept after the terminal closes or its log is trimmed.
    public var codexThread: UUID?
    /// The /goal the agent works toward. Claude Code checks the goal after each turn and goes on until it is met. nil
    /// when there is no goal.
    public var goal: String?
    /// Commands the agent started in the background that were still running when its turn ended, such as a test run it
    /// waits for or a dev server.
    public var background: [String]?
    /// The background command the agent waits for (a test run, not a server). The session's tab glows while that
    /// command runs. A Stop hook names the command. Until then, a command sent to the background mid-turn counts,
    /// unless it looks like a server. nil when the agent waits for no command.
    public var awaiting: String?
    /// The answers offered by the question the agent waits on (an AskUserQuestion with one question and one answer to
    /// pick). `session.choose` picks an answer by its label, as a click on it would. nil for any other kind of wait,
    /// and once the agent goes on.
    public var choices: [String]?
    /// The command the agent's shell tool runs now (`AgentCommand`, from its hooks). nil between commands.
    public var running: String?
    /// The plan limit that stopped the agent. It goes back to nil once the agent does anything else.
    public var limitHit: LimitHit?
    /// When Kelp types "continue" into the session, if the agent is still where the limit stopped it
    /// (`session.continueAt`).
    public var continueAt: Date?
    /// When Kelp went down (a crash, the Mac shutting down) while the agent was mid-turn, so Kelp offers to go on with
    /// it. nil for an agent paused any other way, and once it wakes.
    public var interruptedAt: Date?
    /// The agent that started this one (`kelp session new --agent`). The parent hears how this agent is doing, and ends
    /// it when the parent ends.
    public var parent: String?
    /// The agent this command belongs to (`kelp session new --cmd` run inside the agent). The command shows on the line
    /// under that agent's terminal instead of in its own tab and sidebar row. Unlike a child agent, the command goes on
    /// when the agent ends, and then it gets a tab.
    public var startedBy: String?
    public var role: SessionRole?   // The job Kelp started the session for (`SessionRole`), kept across a restart.
    /// Variables the session was started with on top of its agent's own (`kelp session new --env`), kept so a restart
    /// or a wake reaches the same server. They are stored and shown as the command line is: not for secrets.
    public var env: [String: String]?
    /// The session whose program asked for this one (`session.create` from inside a session, `--outlive` too). The
    /// daemon sets it from the caller's process, never from what the caller sent, so an agent may act on what it
    /// started and nothing more.
    public var origin: String?
    /// Whether Claude Code got Kelp's browser skill, and why ("on · Vite in package.json"). nil for agents without
    /// skills.
    public var browser: String?
    /// Set when the session is working but nothing has been heard from it for minutes (no hook, or no output for an
    /// agent without hooks). The sidebar then says "quiet 34m" instead of showing a working ring that tells nothing.
    /// nil while news keeps coming.
    public var quietSince: Date?
    /// True when the status is a guess read off the screen (an agent without hooks, or one whose hooks went silent). A
    /// guessed status never turns to Done on its own and never sends a notification for Done. nil means the agent
    /// itself reported the status.
    public var guessed: Bool?
    /// The agent's subagents at work now, as id → kind, from its hooks. Subagents run inside the agent and have no tab
    /// of their own.
    public var subagents: [String: String]? { didSet { followSubagents() } }
    /// What each subagent does, keyed by the same id, when the agent reports it (the `title` field of OSC 7501).
    public var subagentTasks: [String: String]? { didSet { followSubagents() } }
    /// This turn's subagents in the order they started, finished ones included. It follows the two fields above and is
    /// cleared when the turn ends.
    public var subagentRuns: [Subagent]?
    public init(
        id: String = UUID().uuidString, worktreeId: String? = nil, cwd: String, command: String, agent: String? = nil,
        status: AgentStatus = .idle, unread: Bool = false, pid: Int32 = 0, createdAt: Date = Date(),
        title: String = "", titleManual: Bool = false, summary: String = "", argv: [String] = []
    ) {
        self.id = id
        self.worktreeId = worktreeId
        self.cwd = cwd
        self.command = command
        self.agent = agent
        self.status = status
        self.statusAt = createdAt
        self.unread = unread
        self.pid = pid
        self.createdAt = createdAt
        self.title = title
        self.titleManual = titleManual
        self.summary = summary
        self.argv = argv
    }
    public var displayTitle: String { title.isEmpty ? (agent ?? Self.shellAgent) : title }
    /// The UI state key for the list of commands the user moved from their agent's line into a tab.
    public static let inTabKey = "run.inTab"
    /// True for a conversation or a standalone program, and false for a terminal or a command on an agent's line.
    public var isChat: Bool { !isTerminal && startedBy == nil }
    /// True when an agent runs in the session, and false for a terminal (`shell`) or a plain command (`custom`, such as
    /// a dev server or a script).
    public var isAgent: Bool { Self.isAgent(agent) }
    public static func isAgent(_ id: String?) -> Bool { ![shellAgent, customAgent].contains(id ?? shellAgent) }
    /// The agent ids of a terminal and of a plain command (`AgentManifest.custom`).
    public static let shellAgent = "shell", customAgent = "custom"
    /// The two agents Kelp knows more about than their manifests say (transcripts, resume, limits, add-ons).
    public static let claudeAgent = "claude", codexAgent = "codex"
    /// True for a plain terminal running a shell. A session or a create call that names no agent is a terminal too.
    public var isTerminal: Bool { Self.isTerminal(agent) }
    public static func isTerminal(_ id: String?) -> Bool { (id ?? shellAgent) == shellAgent }
    /// The command line that a plain command runs (`zsh -lc <line>`), or nil for any other session.
    public var customCommand: String? { Self.customCommand(agent: agent, argv) }
    public static func customCommand(agent: String?, _ argv: [String]) -> String? {
        agent == customAgent && argv.count == 3 && argv[1] == "-lc" ? argv[2] : nil
    }
    /// True when the agent's turn is over and the session stays working only until the awaited command ends. This is
    /// never the case while the agent asks, nor for a server, because `awaiting` comes from a Stop hook.
    public var waitsForCommand: Bool { status == .working && awaiting != nil }
    /// The summary the session's row shows while the agent compacts its conversation (see `compacting`).
    public static let compactingSummary = "Compacting the conversation…"
    /// True while the agent compacts its conversation.
    public var compacting: Bool { summary.hasPrefix(Self.compactingSummary) }
    /// The commands running in the background beside the agent, one per line. The command the agent waits for is left
    /// out, because that is what the agent is doing. Empty once the session's program is gone.
    public var aside: [String] {
        guard status != .exited, status != .paused else { return [] }
        return (background ?? []).filter { !waitsForCommand || $0 != awaiting }.map(AgentCommand.short)
    }
    /// The tooltip for the session's tab and for the background-commands mark. It names the commands, which no row or
    /// tab has room for.
    public var backgroundTip: String? {
        let awaited =
            waitsForCommand
            ? awaiting.map { [String(localized: "Waits for its command:"), AgentCommand.short($0)] } : nil
        let lines = (awaited ?? []) + (aside.isEmpty ? [] : [String(localized: "Running in the background:")] + aside)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    /// The subagents at work: the ones asking for permission first, then the rest in the order they started.
    public var runningSubagents: [Subagent] {
        let running = (subagentRuns ?? []).filter { $0.ended == nil }
        return running.filter { $0.asks == true } + running.filter { $0.asks != true }
    }
    /// The subagents that finished during this turn.
    public var finishedSubagents: [Subagent] { (subagentRuns ?? []).filter { $0.ended != nil } }
    /// Limit: a turn keeps this many finished subagents so the record stays small. A turn that sent off hundreds counts
    /// only these.
    static let finishedKept = 32
    /// Updates `subagentRuns`: a new id in `subagents` has started, and an id gone from it has ended.
    private mutating func followSubagents() {
        guard subagents != nil || subagentRuns != nil else { return }
        let now = Date()
        var runs = subagentRuns ?? []
        for (id, kind) in subagents ?? [:] {
            guard let index = runs.firstIndex(where: { $0.id == id }) else {
                runs.append(Subagent(id: id, kind: kind, task: subagentTasks?[id], started: now))
                continue
            }
            runs[index].kind = kind
            runs[index].ended = nil
            if let task = subagentTasks?[id] { runs[index].task = task }
        }
        for index in runs.indices where runs[index].ended == nil && subagents?[runs[index].id] == nil {
            runs[index].ended = now
            runs[index].asks = nil
        }
        var over = runs.count { $0.ended != nil } - Self.finishedKept
        runs.removeAll { run in
            guard over > 0, run.ended != nil else { return false }
            over -= 1
            return true
        }
        subagentRuns = runs.isEmpty ? nil : runs
    }
    /// Marks which running subagents have a permission dialog open, given their agent ids.
    public mutating func subagentsAsk(_ ids: some Collection<String>) {
        guard var runs = subagentRuns else { return }
        for index in runs.indices {
            runs[index].asks = runs[index].ended == nil && ids.contains(runs[index].id) ? true : nil
        }
        if runs != subagentRuns { subagentRuns = runs }
    }
    /// True when the session ended here while its agent may still run on the host. A remote agent's tmux session
    /// outlives the ssh that showed it (exit 255 means the connection dropped) and its tmux client (exit 1 means it was
    /// killed). tmux exits 0 when the tmux session itself ended.
    public var connectionLost: Bool { status == .exited && tmux != nil && (exitCode ?? 0) != 0 }
    /// True when the session's program ended by itself with an error (exit code 1–127). A code of 128 and up means a
    /// signal stopped it, as closing or Stop does. A terminal's exit code is its last command's, so it does not mean
    /// the terminal failed. Limit: a program that exits with 128 or more by itself reads as stopped.
    public var endedWithError: Bool {
        status == .exited && !isTerminal && (1...127).contains(exitCode ?? 0)
    }
}

extension [Session] {
    /// Returns the agents that `id` started and that haven't ended, plus the agents those started, all the way down.
    public func children(of id: String) -> [Session] {
        filter { $0.parent == id && $0.status != .exited }.flatMap { [$0] + children(of: $0.id) }
    }

    /// Returns a sentence for a question about ending `ids`, saying that the agents they started end with them. Empty
    /// when they started none.
    public func childrenWords(of ids: [String]) -> String {
        let startedCount = filter {
            $0.parent.map(ids.contains) == true && $0.status != .exited && !ids.contains($0.id)
        }.count
        return startedCount == 0 ? "" : " " + String(localized: "\(startedCount) agents they started end too.")
    }
}

extension Worktree {
    /// The name people see: the name they gave the workspace, or else the branch.
    public var displayName: String {
        if note.isEmpty { return branch }
        return isUnnamed ? String(localized: "New Group") : note
    }

    /// True for a placeholder name like "Workspace 3", which a new workspace keeps until its first prompt names it.
    /// People see it as a new group. The stored name stays as the daemon wrote it, because Workspaces.placeholderName
    /// looks for that form.
    public var isUnnamed: Bool { note.hasPrefix("Workspace ") && Int(note.dropFirst("Workspace ".count)) != nil }
}
