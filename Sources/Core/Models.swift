import Foundation

/// A record the daemon keeps (a project, a workspace, a session): each write gives it the next revision, so of two copies
/// (a reply and an event that passed each other, a list read before a change) the one with the higher is the newer.
public protocol Revised: Identifiable where ID == String {
    var revision: Int? { get set }
}

extension Revised {
    /// Older than `other`: it says less than what's already there. nil (from a daemon before revisions) counts as 0.
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

public struct Worktree: Codable, Sendable, Equatable, Revised {
    public var id: String
    public var revision: Int?
    public var repoId: String
    public var branch: String
    public var path: String
    public var note: String
    public var archived: Bool
    public var createdAt: Date
    /// Links to the task it came from and the PR it became: "#123" / "ENG-123".
    public var issue: String
    public var issueURL: String
    public var linearIssueId: String
    public var prNumber: Int?
    public var prURL: String
    /// Branch this one was cut from; when it isn't the repo's base the worktree is part of a PR stack.
    public var base: String
    /// The session whose program made it (`Session.origin`'s kind): an agent works in a workspace it made, across a
    /// restart of the daemon too. nil: the user's.
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
    /// Paused: its process stopped to save memory; resumes its conversation when opened again. "hibernated" on the wire.
    case paused = "hibernated"
    /// The agent says its turn failed (OSC 7501 "error"); it stays so until the next turn.
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
    /// As the agent names it: "5-hour", "weekly", "usage".
    public var kind: String
    /// When it resets, as the agent printed it ("3:40pm", "Oct 20 at 5am"); nil when it didn't say.
    public var resets: String?
    /// When it stopped: `resets` is read from here, so "3pm" stays today's once that has passed.
    public var at: Date
    public init(kind: String, resets: String?, at: Date = Date()) {
        self.kind = kind
        self.resets = resets
        self.at = at
    }
}

/// A subagent of an agent's turn, at work or finished. `kind` is empty when only a terminal report told of it.
public struct Subagent: Codable, Sendable, Equatable, Identifiable {
    public var id: String, kind: String, task: String?
    public var started: Date
    public var ended: Date?
    /// Its permission dialog is open.
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
            // A Stop that waits for one stays working; cut short, none says it ended.
            if status != .working && status != .waiting {
                subagents = nil
                subagentTasks = nil
                subagentRuns = nil
            }
        }
    }
    /// When `status` last changed ("working for 4m", "done 2h ago"); nil for sessions from before it was kept.
    public var statusAt: Date?
    public var unread: Bool
    public var pid: Int32
    public var createdAt: Date
    /// Tab title (from the first prompt, or set by hand — a manual name wins).
    public var title: String
    public var titleManual: Bool
    /// One-line summary of what the agent did / is asking (local model or hooks).
    public var summary: String
    /// Launch options, kept so "Restart" reproduces the session.
    public var argv: [String]
    /// Where the agent works when it left `cwd` (Claude Code going into its `.claude/worktrees/…`), from its hooks; nil
    /// while it works in `cwd`. Paths it prints and its last turn's changes are read there; a restart still starts in `cwd`.
    public var workDir: String?
    /// How far what runs in it got, 0–100, when it says (OSC 7501's `progress`, `kelp report`, ConEmu's OSC 9;4).
    public var progress: Int?
    /// How its program ended: the exit code, or 128 + the signal that stopped it; nil while it runs.
    public var exitCode: Int?
    /// The account profile it started with (Settings › Accounts); nil: the agent's own default login. Kept so a woken or
    /// restarted session comes back on the same account.
    public var profile: String?
    /// The tmux session on a remote project's host its agent runs in (`RemoteHost.command(_:inTmux:)`), so the agent outlives a
    /// dropped connection and the daemon; kept so a wake or a restart attaches to it again. nil elsewhere, and once Kelp
    /// ended that tmux session (Stop, closing the tab).
    public var tmux: String?
    /// The /goal it works toward (Claude Code checks it after each turn and goes on until it's met); nil without one.
    public var goal: String?
    /// Commands it started in the background that still ran when its turn ended (a test run it waits for, a dev server).
    public var background: [String]?
    /// The one of them it waits for (a test run, not a server): its tab glows for it while it works. A Stop says which; one
    /// sent to the background mid-turn counts until then, unless it looks like a server. nil when it waits for none.
    public var awaiting: String?
    /// The command its shell tool runs now (`AgentCommand`, from its hooks); nil between them.
    public var running: String?
    /// The plan limit that stopped it; nil again once it does anything else.
    public var limitHit: LimitHit?
    /// When Kelp types "continue" into it, if it still stands where the limit left it (`session.continueAt`).
    public var continueAt: Date?
    /// The agent that started it (`kelp session new --agent`): it hears how this one is doing and takes it along when it ends.
    public var parent: String?
    /// The agent a command belongs to (`kelp session new --cmd` inside it): the line under that agent's terminal shows it,
    /// instead of a tab and a sidebar row of its own. Unlike a child, it goes on when the agent ends, and gets a tab then.
    public var startedBy: String?
    /// The session whose program asked for it (`session.create` from inside one, `--outlive` too), as the daemon saw the
    /// caller's process, never from what it sent: what an agent starts stays the agent's to act on, and no more than that.
    public var origin: String?
    /// Whether Claude Code got Kelp's browser skill, and why ("on · Vite in package.json"); nil for agents without skills.
    public var browser: String?
    /// Working, but nothing heard from it since then (no hook, or for an agent without hooks no output) for minutes: the
    /// sidebar says "quiet 34m" rather than a working ring that tells nothing. nil while news comes.
    public var quietSince: Date?
    /// Its status is read off the screen, a guess (an agent without hooks, or one whose hooks went silent): it never
    /// says Done on its own nor sends a notification for one. nil: told by the agent itself.
    public var guessed: Bool?
    /// Its own subagents at work now, by id, and what kind each is (its hooks say): they run inside it, with no tab of their own.
    public var subagents: [String: String]? { didSet { followSubagents() } }
    /// What each of them does, by the same id, when the agent says (OSC 7501's `title`).
    public var subagentTasks: [String: String]? { didSet { followSubagents() } }
    /// Its subagents of this turn in the order they started, the finished ones too; follows the two above, ends with the turn.
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
    public var displayTitle: String { title.isEmpty ? (agent ?? "shell") : title }
    /// Where the app keeps the commands moved off their agent's line to a tab (a list in UI state).
    public static let inTabKey = "run.inTab"
    /// A conversation or a program of its own: not a terminal, nor a command on an agent's line.
    public var isChat: Bool { agent != "shell" && startedBy == nil }
    /// An agent runs in it: not a terminal (`shell`) nor a plain command (`custom`: a dev server, a script).
    public var isAgent: Bool { Self.isAgent(agent) }
    public static func isAgent(_ id: String?) -> Bool { !["shell", "custom"].contains(id ?? "shell") }
    /// Its turn is over and it stays only to see that command end. Not while it asks, and not for a server: `awaiting`
    /// comes from a Stop.
    public var waitsForCommand: Bool { status == .working && awaiting != nil }
    /// What runs in the background beside it, each in a line: not the command it waits for, which is what it's doing. Empty
    /// once its program is gone.
    public var aside: [String] {
        guard status != .exited, status != .paused else { return [] }
        return (background ?? []).filter { !waitsForCommand || $0 != awaiting }.map(AgentCommand.short)
    }
    /// The tooltip of its tab and of the mark for what runs beside it: the commands by name, which no row or tab has room for.
    public var backgroundTip: String? {
        let awaited =
            waitsForCommand
            ? awaiting.map { [String(localized: "Waits for its command:"), AgentCommand.short($0)] } : nil
        let lines = (awaited ?? []) + (aside.isEmpty ? [] : [String(localized: "Running in the background:")] + aside)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    /// Its subagents at work: who asks first, then in the order they started.
    public var runningSubagents: [Subagent] {
        let running = (subagentRuns ?? []).filter { $0.ended == nil }
        return running.filter { $0.asks == true } + running.filter { $0.asks != true }
    }
    /// Its subagents that finished this turn.
    public var finishedSubagents: [Subagent] { (subagentRuns ?? []).filter { $0.ended != nil } }
    /// Limit: a turn keeps this many finished ones, so a record stays small; one that sent off hundreds counts only these.
    static let finishedKept = 32
    /// A new id in `subagents` has started, one gone from it has ended.
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
    /// Whose permission dialogs are open, by agent id.
    public mutating func subagentsAsk(_ ids: some Collection<String>) {
        guard var runs = subagentRuns else { return }
        for index in runs.indices {
            runs[index].asks = runs[index].ended == nil && ids.contains(runs[index].id) ? true : nil
        }
        if runs != subagentRuns { subagentRuns = runs }
    }
    /// The folder the agent works in now.
    public var currentDir: String { workDir ?? cwd }
    /// Ended here, its agent maybe still running on the host: a remote agent's tmux session outlives the ssh that showed it
    /// (255: the connection dropped) and its tmux client (1: killed). tmux exits 0 when the session ended.
    public var connectionLost: Bool { status == .exited && tmux != nil && (exitCode ?? 0) != 0 }
    /// Its program ended by itself with an error (exit code 1–127; 128 and up is the signal that stopped it, as closing or
    /// Stop does). A terminal's code is its last command's, not the terminal failing. Limit: a program that exits with 128
    /// or more by itself reads as stopped.
    public var endedWithError: Bool { status == .exited && agent != "shell" && (1...127).contains(exitCode ?? 0) }
}

extension [Session] {
    /// The agent whose line shows the command `s`: nil for any other session, and once that agent ended or went elsewhere.
    public func owner(of session: Session) -> Session? {
        guard let id = session.startedBy, let agent = first(where: { $0.id == id }), agent.status != .exited,
            agent.worktreeId == session.worktreeId
        else { return nil }
        return agent
    }

    /// The agents `id` started that haven't ended, and those they started.
    public func children(of id: String) -> [Session] {
        filter { $0.parent == id && $0.status != .exited }.flatMap { [$0] + children(of: $0.id) }
    }

    /// For a question about ending `ids`: the agents they started end with them. Empty when there are none.
    public func childrenWords(of ids: [String]) -> String {
        let startedCount = filter {
            $0.parent.map(ids.contains) == true && $0.status != .exited && !ids.contains($0.id)
        }.count
        return startedCount == 0 ? "" : " " + String(localized: "\(startedCount) agents they started end too.")
    }
}

public struct DiffComment: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable { case open, sent, resolved }
    public var id: String
    public var worktreeId: String
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var quote: String
    public var text: String
    public var state: State
    /// "old": the lines are removed ones, numbered in the old file; nil: the new file's (or a comment from before sides).
    public var side: String?
    /// HEAD when it was written: what the old file's line numbers are counted in.
    public var commit: String?
    /// The agent that wrote it (a reviewer's finding); nil: the user.
    public var author: String?
    /// The past commit whose diff it's on (full hash); nil: on the folder's changes.
    public var onCommit: String?
    public init(
        id: String = UUID().uuidString, worktreeId: String, file: String, startLine: Int, endLine: Int, quote: String,
        text: String,
        state: State = .open, side: String? = nil, commit: String? = nil, author: String? = nil, onCommit: String? = nil
    ) {
        self.id = id
        self.worktreeId = worktreeId
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.quote = quote
        self.text = text
        self.state = state
        self.side = side
        self.commit = commit
        self.author = author
        self.onCommit = onCommit
    }

    /// Whether it belongs on the diff of `commit` (nil: the folder's changes); a hash matches either way it's cut short.
    public func isOn(_ commit: String?) -> Bool {
        guard let on = onCommit, let commit else { return onCommit == nil && commit == nil }
        return on.hasPrefix(commit) || commit.hasPrefix(on)
    }
}

extension Worktree {
    /// The name people see: their own, or the branch.
    public var displayName: String {
        if note.isEmpty { return branch }
        return isUnnamed ? String(localized: "New Group") : note
    }

    /// "Workspace 3", the name a new workspace keeps until its first prompt names it: a new group to people. The stored name
    /// stays as the daemon wrote it (Workspaces.placeholderName knows it by that).
    public var isUnnamed: Bool { note.hasPrefix("Workspace ") && Int(note.dropFirst("Workspace ".count)) != nil }
}
