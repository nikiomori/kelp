import Foundation

// Projects (repos), their workspaces (worktrees: workspaces in the project's folder, or git worktrees of their own) and the
// sessions in them. Results are the records (Repo, Worktree, Session) or what's noted.

/// A folder in a repository adds the repository. One outside any: `init` true runs `git init` there, false adds the
/// folder as it is (no git), and without `init` the call fails with `notARepository` (the app asks which).
public struct RepoAdd: RPCMethod {
    public static let name = "repo.add"; public typealias Result = Repo; public var path: String, name: String?, `init`: Bool?
    public init(path: String, name: String? = nil, `init`: Bool? = nil) { self.path = path; self.name = name; self.`init` = `init` }
    public static let notARepository = RPCError(
        code: -32003, message: "Not a Git repository: add it with init true (git init there) or false (as it is, without git); kelp repo add --init or --no-git.")
}
/// All projects.
public struct RepoList: RPCMethod { public static let name = "repo.list"; public typealias Result = [Repo]; public init() {} }
/// The workspace of the chats outside any project (No Project), a plain folder made the first time; each agent started on it works in a folder of its own inside.
public struct ScratchEnsure: InternalMethod { public static let name = "scratch.ensure"; public typealias Result = Worktree; public init() {} }
/// The project's folder moved: the project and its workspaces point at `path`.
public struct RepoRelocate: RPCMethod {
    public static let name = "repo.relocate"; public typealias Result = Repo; public var id: String, path: String
    public init(id: String, path: String) { self.id = id; self.path = path }
}
/// The project's own name; an empty one gives back its folder's. Its path, workspaces and agents stay as they are.
public struct RepoRename: RPCMethod {
    public static let name = "repo.rename"; public typealias Result = Repo; public var id: String, name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
/// Its workspaces go with it, and their agents stop.
public struct RepoRemove: RPCMethod {
    public static let name = "repo.remove"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}

/// A new group in the project: a screen of its own in the project's folder.
public struct WorkspaceCreate: RPCMethod {
    public static let name = "workspace.create"; public typealias Result = Worktree; public var repoId: String
    public init(repoId: String) { self.repoId = repoId }
}
/// A git worktree on a new `branch` from `base`; `tabs`/`setup` false skip .kelp.yaml's. Adds `setupNeedsTrust` or `setupSession`.
public struct WorktreeCreate: RPCMethod {
    public static let name = "worktree.create"
    public var repoId: String, branch: String?, base: String?, note: String?, tabs: Bool?, setup: Bool?
    /// `branch` is there already (a local one, or "origin/x"): checked out as it is, not made from `base`.
    public var existing: Bool?
    /// A pull request's number: its head is fetched into `branch` (else "pr-N") and checked out.
    public var pr: Int?
    public init(repoId: String, branch: String? = nil, base: String? = nil, note: String? = nil, tabs: Bool? = nil, setup: Bool? = nil,
                existing: Bool? = nil, pr: Int? = nil) {
        self.repoId = repoId; self.branch = branch; self.base = base; self.note = note; self.tabs = tabs; self.setup = setup
        self.existing = existing; self.pr = pr
    }
    /// The worktree's own fields, and beside them what its .kelp.yaml setup needs.
    public struct Result: Codable, Sendable, Equatable {
        public var worktree: Worktree, setupNeedsTrust: Bool?, setupSession: String?
        public init(worktree: Worktree, setupNeedsTrust: Bool? = nil, setupSession: String? = nil) {
            self.worktree = worktree; self.setupNeedsTrust = setupNeedsTrust; self.setupSession = setupSession
        }
        private enum Extra: String, CodingKey { case setupNeedsTrust, setupSession }
        public init(from d: Decoder) throws {
            worktree = try Worktree(from: d)
            let c = try d.container(keyedBy: Extra.self)
            setupNeedsTrust = try c.decodeIfPresent(Bool.self, forKey: .setupNeedsTrust)
            setupSession = try c.decodeIfPresent(String.self, forKey: .setupSession)
        }
        public func encode(to e: Encoder) throws {
            try worktree.encode(to: e)
            var c = e.container(keyedBy: Extra.self)
            try c.encodeIfPresent(setupNeedsTrust, forKey: .setupNeedsTrust); try c.encodeIfPresent(setupSession, forKey: .setupSession)
        }
    }
}
/// Workspaces, of project `repoId` when given; `archived` lists those instead.
public struct WorktreeList: RPCMethod {
    public static let name = "worktree.list"; public typealias Result = [Worktree]; public var repoId: String?, archived: Bool?
    public init(repoId: String? = nil, archived: Bool? = nil) { self.repoId = repoId; self.archived = archived }
}
/// Out of sight with its folder kept: its agents pause.
public struct WorktreeArchive: RPCMethod {
    public static let name = "worktree.archive"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// `force`: uncommitted changes go too; `dropCommits`: so do commits on no other branch.
public struct WorktreeRemove: RPCMethod {
    public static let name = "worktree.remove"; public typealias Result = Done
    public var id: String, force: Bool?, dropCommits: Bool?
    public init(id: String, force: Bool? = nil, dropCommits: Bool? = nil) { self.id = id; self.force = force; self.dropCommits = dropCommits }
}
/// Brings an archived workspace back.
public struct WorktreeUnarchive: RPCMethod {
    public static let name = "worktree.unarchive"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// → how many commits on its branch no other branch or remote has (lost if it's deleted).
public struct WorktreeUnmerged: RPCMethod {
    public static let name = "worktree.unmerged"; public typealias Result = Int
    public var id: String
    public init(id: String) { self.id = id }
}
/// Whether its folder has uncommitted changes.
public struct WorktreeDirty: RPCMethod {
    public static let name = "worktree.dirty"; public typealias Result = Bool
    public var id: String
    public init(id: String) { self.id = id }
}

/// All sessions, or those of workspace `worktreeId`.
public struct SessionList: RPCMethod {
    public static let name = "session.list"; public typealias Result = [Session]; public var worktreeId: String?
    public init(worktreeId: String? = nil) { self.worktreeId = worktreeId }
}
/// → {history}: what it printed so far (base64); then `event.output` for this connection.
public struct SessionAttach: RPCMethod {
    public static let name = "session.attach"; public var id: String
    public init(id: String) { self.id = id }
    public struct Result: Codable, Sendable, Equatable { public var history: String; public init(history: String) { self.history = history } }
}
/// This connection stops following the session (`session.attach`). The session keeps running.
public struct SessionDetach: RPCMethod {
    public static let name = "session.detach"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// The user's keys (`base64`), or `text` as it is.
public struct SessionWrite: RPCMethod {
    public static let name = "session.write"; public typealias Result = Done; public var id: String, base64: String?, text: String?
    public init(id: String, base64: String? = nil, text: String? = nil) { self.id = id; self.base64 = base64; self.text = text }
}
/// `text`, then Enter (unless `enter` is false) a beat later so a TUI takes it as a submit.
public struct SessionSend: RPCMethod {
    public static let name = "session.send"; public typealias Result = Done; public var id: String, text: String, enter: Bool?
    public init(id: String, text: String, enter: Bool? = nil) { self.id = id; self.text = text; self.enter = enter }
}
/// The size of its terminal.
public struct SessionResize: RPCMethod {
    public static let name = "session.resize"; public typealias Result = Done; public var id: String, cols: Int?, rows: Int?
    public init(id: String, cols: Int?, rows: Int?) { self.id = id; self.cols = cols; self.rows = rows }
}
/// Ends the session.
public struct SessionKill: RPCMethod {
    public static let name = "session.kill"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// `answer`: allow | deny, to the menu on screen → false when there is none. `question`: what the answer was given to (the
/// session's summary a banner showed) → false too once the agent asks something else, or several things at once.
public struct SessionChoose: RPCMethod {
    public static let name = "session.choose"; public typealias Result = Bool; public var id: String, answer: String, question: String?
    public init(id: String, answer: String, question: String? = nil) { self.id = id; self.answer = answer; self.question = question }
}
/// A permission question's hook (Claude Code's PermissionRequest) waits here for Allow or Deny given in Kelp: "allow",
/// "deny", or nil once it was answered in the terminal or ten minutes passed. The agent's own menu stays on screen
/// meanwhile (Claude Code shows it while the hook runs), so the terminal can answer too.
public struct SessionPermissionWait: InternalMethod {
    public static let name = "session.permissionWait"; public typealias Result = String?
    public static var timeout: TimeInterval? { 620 }
    public var id: String
    public init(id: String) { self.id = id }
}
/// Kept in the login keychain, read when the agent starts. No `value`: deleted.
public struct AgentSetSecret: InternalMethod {
    public static let name = "agent.setSecret"; public typealias Result = Done; public var agent: String, key: String, value: String?
    public init(agent: String, key: String, value: String? = nil) { self.agent = agent; self.key = key; self.value = value }
}
/// The ports the workspace's sessions listen on.
public struct PortsList: RPCMethod {
    public static let name = "ports.list"; public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
    /// A port a process of one of the workspace's sessions listens on; on a remote project's host, one in its folder.
    public struct Port: Codable, Sendable, Equatable {
        /// `session`: "" when it can't be told. `pid` 0: none, a forwarding asked for by hand.
        public var port: Int, pid: Int32, command: String, session: String
        /// On a remote project: its host, the port on this Mac once forwarded, and true when the host can't be asked
        /// (this is its last answer).
        public var host: String?, here: Int?, offline: Bool?
        public init(port: Int, pid: Int32, command: String, session: String, host: String? = nil, here: Int? = nil, offline: Bool? = nil) {
            self.port = port; self.pid = pid; self.command = command; self.session = session
            self.host = host; self.here = here; self.offline = offline
        }
    }
    public typealias Result = [Port]
}
/// Only a process one of the workspace's sessions started.
public struct PortsStop: RPCMethod {
    public static let name = "ports.stop"; public typealias Result = Done; public var worktreeId: String, pid: Int?
    public init(worktreeId: String, pid: Int?) { self.worktreeId = worktreeId; self.pid = pid }
}
/// A port of a remote project's host brought to this Mac: `port` as listed, or `target` ("5432", "db.internal:5432").
/// Connects when the connection is gone.
public struct PortsForward: InternalMethod {
    public static let name = "ports.forward"; public var worktreeId: String, port: Int?, target: String?
    public init(worktreeId: String, port: Int? = nil, target: String? = nil) { self.worktreeId = worktreeId; self.port = port; self.target = target }
    public struct Forwarded: Codable, Sendable, Equatable {
        /// On this Mac.
        public var port: Int
        public init(port: Int) { self.port = port }
    }
    public typealias Result = Forwarded
}
public struct PortsUnforward: InternalMethod {
    public static let name = "ports.unforward"; public typealias Result = Done; public var worktreeId: String, port: Int
    public init(worktreeId: String, port: Int) { self.worktreeId = worktreeId; self.port = port }
}
/// CPU and memory of each running session's processes.
public struct SessionUsage: RPCMethod {
    public static let name = "session.usage"
    public init() {}
    /// CPU (ps's %, summed over the session's processes; 100 = one core) and resident memory of a live session.
    public struct Usage: Codable, Sendable, Equatable {
        public var session: String, cpu: Double, memory: Int, processes: Int
        public init(session: String, cpu: Double, memory: Int, processes: Int) {
            self.session = session; self.cpu = cpu; self.memory = memory; self.processes = processes
        }
    }
    public typealias Result = [Usage]
}
/// The program a shell runs in the foreground (closing it would stop that), or null.
public struct SessionBusy: RPCMethod {
    public static let name = "session.busy"; public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}
/// The commands its agent ran with its shell tool, oldest first: the last 100, kept while the background service runs.
public struct SessionCommands: RPCMethod {
    public static let name = "session.commands"; public typealias Result = [AgentCommand]
    public var id: String
    public init(id: String) { self.id = id }
}
/// The last `bytes` it printed, as text.
public struct SessionRead: RPCMethod {
    public static let name = "session.read"; public typealias Result = String; public var id: String, bytes: Int?
    public init(id: String, bytes: Int? = nil) { self.id = id; self.bytes = bytes }
}
/// session.read with room for "Copy Context".
public struct SessionContext: RPCMethod {
    public static let name = "session.context"; public typealias Result = String; public var id: String, bytes: Int?
    public init(id: String, bytes: Int? = nil) { self.id = id; self.bytes = bytes }
}
/// Clears its unread mark.
public struct SessionMarkRead: RPCMethod {
    public static let name = "session.markRead"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// "continue" typed into a session a plan limit stopped, by the daemon, so Kelp's window can be closed by then. nil takes it back.
public struct SessionContinueAt: InternalMethod {
    public static let name = "session.continueAt"; public typealias Result = Done
    public var id: String, at: Date?
    public init(id: String, at: Date?) { self.id = id; self.at = at }
}

/// Sets its unread mark.
public struct SessionMarkUnread: RPCMethod {
    public static let name = "session.markUnread"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// → {turn, hasBase}: the files its last turn changed and how long it took; null when the session isn't running.
public struct SessionTurn: RPCMethod {
    public static let name = "session.turn"; public var id: String
    public init(id: String) { self.id = id }
    /// One turn of the agent: what it changed by the time it stopped, and how long it worked.
    public struct Turn: Codable, Sendable, Equatable {
        public struct File: Codable, Sendable, Equatable {
            public var path: String, added: Int, removed: Int
            public init(path: String, added: Int, removed: Int) { self.path = path; self.added = added; self.removed = removed }
        }
        public var files: [File], seconds: Double
        public init(files: [File], seconds: Double) { self.files = files; self.seconds = seconds }
    }
    public struct Info: Codable, Sendable, Equatable {
        public var turn: Turn?, hasBase: Bool
        public init(turn: Turn?, hasBase: Bool) { self.turn = turn; self.hasBase = hasBase }
    }
    public typealias Result = Info?
}
/// The session's turns, the newest first (the last 20): how its folder was as each began, with the prompt that started
/// it. None for a remote project's, where no snapshots are taken.
public struct SessionTurns: RPCMethod {
    public static let name = "session.turns"; public typealias Result = [Mark]
    public var id: String
    public init(id: String) { self.id = id }
    /// A turn's start: `tree` is the folder then (a snapshot in the project's git, which git's cleanup may take after
    /// two weeks), `head` its HEAD then.
    public struct Mark: Codable, Sendable, Equatable, Identifiable {
        public var id: String, session: String, tree: String, head: String?, folder: String, prompt: String, at: Date
        public init(id: String = UUID().uuidString, session: String, tree: String, head: String?, folder: String, prompt: String,
                    at: Date = Date()) {
            self.id = id; self.session = session; self.tree = tree; self.head = head
            self.folder = folder; self.prompt = prompt; self.at = at
        }
    }
}

/// A turn of the agent's undone: its folder put back as it was when `turn` began. Without `apply`, what would go back
/// and the folder's state now; with it, done only while the folder is still that `state`, answering with the state after
/// (for `session.turnRedo`). Refused while the agent works,
/// after commits since the turn began, and with another agent in the folder. `.env` files stay as they are.
public struct SessionTurnUndo: RPCMethod {
    public static let name = "session.turnUndo"; public typealias Result = Plan
    public var id: String, turn: String, apply: Bool?, state: String?
    public init(id: String, turn: String, apply: Bool? = nil, state: String? = nil) {
        self.id = id; self.turn = turn; self.apply = apply; self.state = state
    }
    public struct Plan: Codable, Sendable, Equatable {
        public var files: [String], state: String
        public init(files: [String], state: String) { self.files = files; self.state = state }
    }
}

/// The last `session.turnUndo` taken back: the folder as it was before it, while it is still `state` (the Plan that
/// undo answered with). `turn` is the one that was undone.
public struct SessionTurnRedo: RPCMethod {
    public static let name = "session.turnRedo"; public typealias Result = Done
    public var id: String, turn: String, state: String
    public init(id: String, turn: String, state: String) { self.id = id; self.turn = turn; self.state = state }
}

/// What a finished Claude Code agent did and what's left, in a line, from a fork of its conversation that leaves the
/// conversation as it was; kept as its summary. nil: not Claude Code, or it couldn't be asked.
public struct SessionRecap: InternalMethod {
    public static let name = "session.recap"; public typealias Result = String?
    public static var timeout: TimeInterval? { 100 }
    public var id: String
    public init(id: String) { self.id = id }
}

/// The agent's last message, from its transcript.
public struct SessionLastReply: RPCMethod {
    public static let name = "session.lastReply"; public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}

/// A running session's status and where it came from: a hook, the program's own report, the screen. nil: it isn't running.
public struct SessionWhy: RPCMethod {
    public static let name = "session.why"; public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}

/// What a session's status went through and the hooks it heard, oldest first, a line each. Kept after it ended; empty when
/// nothing happened yet.
public struct SessionTrail: RPCMethod {
    public static let name = "session.trail"; public typealias Result = String
    public var id: String
    public init(id: String) { self.id = id }
}

/// Clones `url` into a new folder in `parent` (`folder`, else named after the repository) → the added project; progress
/// comes as `event.clone` {id, line}.
public struct RepoClone: RPCMethod {
    public static let name = "repo.clone"; public typealias Result = Repo; public var url: String, parent: String, folder: String?, id: String?
    public static var timeout: TimeInterval? { nil }   // a big repository takes as long as it takes; Cancel stops it
    public init(url: String, parent: String, folder: String? = nil, id: String? = nil) {
        self.url = url; self.parent = parent; self.folder = folder; self.id = id
    }

    /// "git@github.com:me/app.git", "https://gitlab.com/me/app" → "app".
    public static func folderName(_ url: String) -> String {
        var n = url.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { "/:".contains($0) }).last.map(String.init) ?? ""
        if n.hasSuffix(".git") { n = String(n.dropLast(4)) }
        return n
    }
}
/// Stops clone `id` (its half-made folder is removed).
public struct RepoCloneCancel: RPCMethod {
    public static let name = "repo.cloneCancel"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
