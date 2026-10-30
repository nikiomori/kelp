import Foundation

// Projects (repos), their workspaces (worktrees: desks in the project's folder, or git worktrees of their own) and the
// sessions in them. Results are the records (Repo, Worktree, Session) or what's noted.

/// A folder in a repository adds the repository. One outside any: `init` true runs `git init` there, false adds the
/// folder as it is (no git), and without `init` the call fails with `notARepository` (the app asks which).
public struct RepoAdd: RPCMethod {
    public static let name = "repo.add"; public typealias Result = Repo; public var path: String, name: String?, `init`: Bool?
    public init(path: String, name: String? = nil, `init`: Bool? = nil) { self.path = path; self.name = name; self.`init` = `init` }
    public static let notARepository = RPCError(
        code: -32003, message: "Not a Git repository: add it with init true (git init there) or false (as it is, without git); kelp repo add --init or --no-git.")
}
public struct RepoList: RPCMethod { public static let name = "repo.list"; public typealias Result = [Repo]; public init() {} }
/// The scratch project's workspace, made (with a git repo of its own) the first time.
public struct ScratchEnsure: RPCMethod { public static let name = "scratch.ensure"; public typealias Result = Worktree; public init() {} }
/// The project's folder moved: the project and its desks point at `path`.
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

public struct WorkspaceCreate: RPCMethod {
    public static let name = "workspace.create"; public typealias Result = Worktree; public var repoId: String
    public init(repoId: String) { self.repoId = repoId }
}
/// A git worktree on a new `branch` from `base`; `tabs`/`setup` false skip .kelp.yaml's. Adds `setupNeedsTrust` or `setupSession`.
public struct WorktreeCreate: RPCMethod {
    public static let name = "worktree.create"
    public var repoId: String, branch: String?, base: String?, note: String?, tabs: Bool?, setup: Bool?
    public init(repoId: String, branch: String? = nil, base: String? = nil, note: String? = nil, tabs: Bool? = nil, setup: Bool? = nil) {
        self.repoId = repoId; self.branch = branch; self.base = base; self.note = note; self.tabs = tabs; self.setup = setup
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
public struct WorktreeDirty: RPCMethod {
    public static let name = "worktree.dirty"; public typealias Result = Bool
    public var id: String
    public init(id: String) { self.id = id }
}

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
public struct SessionResize: RPCMethod {
    public static let name = "session.resize"; public typealias Result = Done; public var id: String, cols: Int?, rows: Int?
    public init(id: String, cols: Int?, rows: Int?) { self.id = id; self.cols = cols; self.rows = rows }
}
public struct SessionKill: RPCMethod {
    public static let name = "session.kill"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// `answer`: allow | deny, to the menu on screen → false when there is none.
public struct SessionChoose: RPCMethod {
    public static let name = "session.choose"; public typealias Result = Bool; public var id: String, answer: String
    public init(id: String, answer: String) { self.id = id; self.answer = answer }
}
/// Kept in the login keychain, read when the agent starts. No `value`: deleted.
public struct AgentSetSecret: RPCMethod {
    public static let name = "agent.setSecret"; public typealias Result = Done; public var agent: String, key: String, value: String?
    public init(agent: String, key: String, value: String? = nil) { self.agent = agent; self.key = key; self.value = value }
}
public struct PortsList: RPCMethod {
    public static let name = "ports.list"; public var worktreeId: String
    public init(worktreeId: String) { self.worktreeId = worktreeId }
    /// A port a process of one of the workspace's sessions listens on.
    public struct Port: Codable, Sendable, Equatable {
        public var port: Int, pid: Int32, command: String, session: String
        public init(port: Int, pid: Int32, command: String, session: String) {
            self.port = port; self.pid = pid; self.command = command; self.session = session
        }
    }
    public typealias Result = [Port]
}
/// Only a process one of the workspace's sessions started.
public struct PortsStop: RPCMethod {
    public static let name = "ports.stop"; public typealias Result = Done; public var worktreeId: String, pid: Int?
    public init(worktreeId: String, pid: Int?) { self.worktreeId = worktreeId; self.pid = pid }
}
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
public struct SessionMarkRead: RPCMethod {
    public static let name = "session.markRead"; public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// "continue" typed into a session a plan limit stopped, by the daemon, so Kelp's window can be closed by then. nil takes it back.
public struct SessionContinueAt: RPCMethod {
    public static let name = "session.continueAt"; public typealias Result = Done
    public var id: String, at: Date?
    public init(id: String, at: Date?) { self.id = id; self.at = at }
}

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
/// The agent's last message, from its transcript.
public struct SessionLastReply: RPCMethod {
    public static let name = "session.lastReply"; public typealias Result = String?
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
