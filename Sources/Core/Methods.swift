import Foundation

// RPC methods declared as types (see `RPCMethod`). The daemon answers them in `Handled` conformances.

/// The running daemon: the app compares it with the kelpd it ships to spot a stale one after an update.
public struct DaemonInfo: RPCMethod {
    public static let name = "daemon.info"
    public struct Result: Codable, Sendable {
        public var path: String, binaryMTime: Double?, pid: Int, liveSessions: Int   // no binaryMTime before 2026-10-19
        public init(path: String, binaryMTime: Double?, pid: Int, liveSessions: Int) {
            self.path = path; self.binaryMTime = binaryMTime; self.pid = pid; self.liveSessions = liveSessions
        }
    }
    public init() {}
}

/// What the app restores (`UIState`): `key` → its value or null; `prefix` → {key: value} for every key that starts with it.
public struct StateGet: RPCMethod {
    public static let name = "state.get"
    public typealias Result = JSONValue
    public var key: String?, prefix: String?
    public init(key: String? = nil, prefix: String? = nil) { self.key = key; self.prefix = prefix }
}

/// A nil (or null) value deletes the key.
public struct StateSet: RPCMethod {
    public static let name = "state.set"
    public typealias Result = Done
    public var key: String, value: JSONValue?
    public init(key: String, value: JSONValue?) { self.key = key; self.value = value }
}

/// An empty title names the session from its task again.
public struct SessionRename: RPCMethod {
    public static let name = "session.rename"
    public typealias Result = Done
    public var id: String, title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// How full the agent's conversation is (Claude Code transcripts); nil when that isn't known.
public struct SessionContextWindow: RPCMethod {
    public static let name = "session.contextWindow"
    public struct Usage: Codable, Sendable, Equatable {
        public var used: Int, window: Int
        public init(used: Int, window: Int) { self.used = used; self.window = window }
    }
    public typealias Result = Usage?
    public var id: String
    public init(id: String) { self.id = id }
}

/// What fills a Claude Code conversation's context since its last compaction: the base it starts with (system prompt,
/// tools, CLAUDE.md, skills: the first request) and the parts after it, estimated from the transcript and scaled so that
/// base + parts make the tokens the last reply counted. nil when that isn't known (other agents, no reply yet).
public struct SessionContextParts: RPCMethod {
    public static let name = "session.contextParts"
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// What Read returned, by file.
        case files
        /// What Bash and the other tools printed, by command or tool.
        case commands
        /// The agent's replies (and what it wrote with Edit / Write), your messages, Claude Code's notes to it.
        case conversation
        /// What /compact kept of the conversation before it.
        case summary
    }
    public struct Item: Codable, Sendable, Equatable {
        /// "payment.ts", "npm test", "its replies"; `count` times ("npm test ×38", "your 9 messages").
        public var label: String, tokens: Int, count: Int
        public init(label: String, tokens: Int, count: Int = 1) { self.label = label; self.tokens = tokens; self.count = count }
    }
    public struct Part: Codable, Sendable, Equatable {
        public var kind: Kind, tokens: Int
        /// The biggest three, biggest first; `more` items besides them.
        public var top: [Item], more: Int
        public init(kind: Kind, tokens: Int, top: [Item], more: Int) { self.kind = kind; self.tokens = tokens; self.top = top; self.more = more }
    }
    public struct Parts: Codable, Sendable, Equatable {
        /// In Kind's order, the empty ones left out.
        public var base: Int, parts: [Part]
        public init(base: Int, parts: [Part]) { self.base = base; self.parts = parts }
    }
    public typealias Result = Parts?
    public var id: String
    public init(id: String) { self.id = id }
}

/// The project's other git worktrees (agents' `.claude/worktrees/…`, older Kelp workspaces) and the disk each takes,
/// biggest first: they grow with every build and nothing in the folder itself shows it.
public struct RepoWorktreeSizes: RPCMethod {
    public static let name = "repo.worktreeSizes"
    public struct Item: Codable, Sendable, Equatable {
        public var path: String, bytes: Int
        /// Nothing uncommitted or untracked, not locked, not one of Kelp's workspaces (those go with Delete Workspace).
        public var removable: Bool
        public init(path: String, bytes: Int, removable: Bool) { self.path = path; self.bytes = bytes; self.removable = removable }
    }
    public typealias Result = [Item]
    public var id: String
    public init(id: String) { self.id = id }
}

/// Removes those of `paths` that are still clean, as `git worktree remove` without --force does (one with changes,
/// untracked files or a lock stays), each with its branch when that branch's commits are on another one too.
public struct RepoRemoveWorktrees: RPCMethod {
    public static let name = "repo.removeWorktrees"
    public struct Result: Codable, Sendable {
        public var removed: [String], kept: [String: String]   // kept: path → why
        public init(removed: [String], kept: [String: String]) { self.removed = removed; self.kept = kept }
    }
    public var id: String, paths: [String]
    public init(id: String, paths: [String]) { self.id = id; self.paths = paths }
}

/// The workspace's name.
public struct WorktreeNote: RPCMethod {
    public static let name = "worktree.note"
    public typealias Result = Done
    public var id: String, note: String
    public init(id: String, note: String) { self.id = id; self.note = note }
}

/// Throws away one hunk of a file's unstaged changes (index `hunk` of its unstaged diff) in workspace `id`. `header`
/// is the hunk's "@@ … @@" line as the caller saw it: if the file changed since, nothing is thrown away.
public struct GitDiscardHunk: RPCMethod {
    public static let name = "git.discardHunk"
    public typealias Result = Done
    public var id: String, file: String, hunk: Int, header: String
    /// The hunk's full text as shown (GitKit's `Hunk.fingerprint`): with it, a hunk whose lines changed since is refused
    /// even when its header didn't. Optional, so older callers keep working.
    public var fingerprint: String?
    public init(id: String, file: String, hunk: Int, header: String, fingerprint: String? = nil) {
        self.id = id; self.file = file; self.hunk = hunk; self.header = header; self.fingerprint = fingerprint
    }
}

/// The folders in `path` on `host` (~ is the host's home), over the host's shared SSH connection: the folder's full
/// path there, whether it's in a git repository, and its subfolders, hidden ones left out, each marked when it's a
/// repository. A host Kelp can't reach fails here, with ssh's reason.
public struct RemoteListFolders: RPCMethod {
    public static let name = "remote.listFolders"
    public struct Folder: Codable, Sendable, Equatable {
        public var name: String, git: Bool
        public init(name: String, git: Bool) { self.name = name; self.git = git }
    }
    public struct Result: Codable, Sendable {
        public var path: String, repo: Bool, folders: [Folder]
        public init(path: String, repo: Bool, folders: [Folder]) { self.path = path; self.repo = repo; self.folders = folders }
    }
    public var host: String, path: String
    public init(host: String, path: String) { self.host = host; self.path = path }
}

/// What a program in the session says it's doing (`kelp report`; the same as writing OSC 7501 itself): `state` is idle,
/// working, blocked, done, error or clear; `message` shows on its row's card, `progress` (0–100) on its mark while it works.
public struct SessionReport: RPCMethod {
    public static let name = "session.report"
    public typealias Result = Done
    public var id: String, state: String, message: String?, progress: Int?, kind: String?
    public init(id: String, state: String, message: String? = nil, progress: Int? = nil, kind: String? = nil) {
        self.id = id; self.state = state; self.message = message; self.progress = progress; self.kind = kind
    }
}

/// herdr's agent report, which fx sends to `HERDR_SOCKET_PATH` (kelpd's socket for it): `pane_id` is the session, `state`
/// idle, working or blocked. herdr's other calls (`pane.rename`…) aren't Kelp's: refused.
public struct PaneReportAgent: RPCMethod {
    public static let name = "pane.report_agent"; public typealias Result = Done
    public var paneId: String, state: String
    enum CodingKeys: String, CodingKey { case paneId = "pane_id", state }
    public init(paneId: String, state: String) { self.paneId = paneId; self.state = state }
}

/// Whether this connection wants the daemon's broadcast events. `kelp attach`'s control connection only sends sizes:
/// without this, every open terminal would be one more reader of every event.
public struct ClientEvents: RPCMethod {
    public static let name = "client.events"; public typealias Result = Done
    public var events: Bool
    public init(events: Bool) { self.events = events }
}
