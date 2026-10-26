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
    public init(id: String = UUID().uuidString, name: String, path: String, baseBranch: String = "main", copyFiles: [String] = [".env", ".env.local"]) {
        self.id = id; self.name = name; self.path = path; self.baseBranch = baseBranch; self.copyFiles = copyFiles
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
    public init(id: String = UUID().uuidString, repoId: String, branch: String, path: String, note: String = "", archived: Bool = false,
                createdAt: Date = Date(), issue: String = "", issueURL: String = "", linearIssueId: String = "",
                prNumber: Int? = nil, prURL: String = "", base: String = "") {
        self.base = base
        self.id = id; self.repoId = repoId; self.branch = branch; self.path = path
        self.note = note; self.archived = archived; self.createdAt = createdAt
        self.issue = issue; self.issueURL = issueURL; self.linearIssueId = linearIssueId; self.prNumber = prNumber; self.prURL = prURL
    }
}

public enum AgentStatus: String, Codable, Sendable {
    case idle, working, waiting, done, exited
    /// Process stopped to save memory; resumes its conversation when opened again.
    case hibernated
    /// The agent says its turn failed (OSC 7501 "error"); it stays so until the next turn.
    case error
    public var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Needs you"
        case .done: "Done"
        case .exited: "Exited"
        case .hibernated: "Paused"
        case .error: "Failed"
        }
    }
}

public struct Session: Codable, Sendable, Equatable, Revised {
    public var id: String
    public var revision: Int?
    public var worktreeId: String?
    public var cwd: String
    public var command: String
    public var agent: String?
    public var status: AgentStatus { didSet { if status != oldValue { statusAt = Date() } } }
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
    /// dropped connection and the daemon; kept so a wake or a restart attaches to it again. nil elsewhere.
    public var tmux: String?
    /// The /goal it works toward (Claude Code checks it after each turn and goes on until it's met); nil without one.
    public var goal: String?
    /// Commands it started in the background that still ran when its turn ended (a test run it waits for, a dev server).
    public var background: [String]?
    public init(id: String = UUID().uuidString, worktreeId: String? = nil, cwd: String, command: String, agent: String? = nil,
                status: AgentStatus = .idle, unread: Bool = false, pid: Int32 = 0, createdAt: Date = Date(),
                title: String = "", titleManual: Bool = false, summary: String = "", argv: [String] = []) {
        self.id = id; self.worktreeId = worktreeId; self.cwd = cwd; self.command = command; self.agent = agent
        self.status = status; self.statusAt = createdAt; self.unread = unread; self.pid = pid; self.createdAt = createdAt
        self.title = title; self.titleManual = titleManual; self.summary = summary; self.argv = argv
    }
    public var displayTitle: String { title.isEmpty ? (agent ?? "shell") : title }
    /// The folder the agent works in now.
    public var currentDir: String { workDir ?? cwd }
    /// Ended here, its agent maybe still running on the host: a remote agent's tmux session outlives the ssh that showed it
    /// (255: the connection dropped) and its tmux client (1: killed). tmux exits 0 when the session ended.
    public var connectionLost: Bool { status == .exited && tmux != nil && (exitCode ?? 0) != 0 }
}

public struct DiffComment: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case open, sent, resolved }
    public var id: String
    public var worktreeId: String
    public var file: String
    public var startLine: Int
    public var endLine: Int
    public var quote: String
    public var text: String
    public var state: State
    public init(id: String = UUID().uuidString, worktreeId: String, file: String, startLine: Int, endLine: Int, quote: String, text: String,
                state: State = .open) {
        self.id = id; self.worktreeId = worktreeId; self.file = file; self.startLine = startLine
        self.endLine = endLine; self.quote = quote; self.text = text; self.state = state
    }
}

extension Worktree {
    /// The name people see: their own, or the branch.
    public var displayName: String { note.isEmpty ? branch : note }
}
