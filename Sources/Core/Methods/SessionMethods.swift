import Foundation

// The session.* methods: the sessions in a workspace, what they printed and did, their input, and their turns.

/// Lists all sessions, or the sessions of workspace `worktreeId`.
public struct SessionList: RPCMethod {
    public static let name = "session.list"
    public typealias Result = [Session]
    public var worktreeId: String?
    public init(worktreeId: String? = nil) { self.worktreeId = worktreeId }
}
/// Follows a session. It answers {history}, what the session printed so far (base64), and then sends `event.output` to
/// this connection.
public struct SessionAttach: RPCMethod {
    public static let name = "session.attach"
    public var id: String
    public init(id: String) { self.id = id }
    public struct Result: Codable, Sendable, Equatable {
        public var history: String
        public init(history: String) { self.history = history }
    }
}
/// This connection stops following the session (`session.attach`). The session keeps running.
public struct SessionDetach: RPCMethod {
    public static let name = "session.detach"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// Writes the user's keys (`base64`), or `text` as it is, to the session.
public struct SessionWrite: RPCMethod {
    public static let name = "session.write"
    public typealias Result = Done
    public var id: String, base64: String?, text: String?
    public init(id: String, base64: String? = nil, text: String? = nil) {
        self.id = id
        self.base64 = base64
        self.text = text
    }
}
/// Sends `text`, then Enter a beat later (unless `enter` is false), so a TUI takes it as a submit.
public struct SessionSend: RPCMethod {
    public static let name = "session.send"
    public typealias Result = Done
    public var id: String, text: String, enter: Bool?
    public init(id: String, text: String, enter: Bool? = nil) {
        self.id = id
        self.text = text
        self.enter = enter
    }
}
/// Sets the size of the session's terminal.
public struct SessionResize: RPCMethod {
    public static let name = "session.resize"
    public typealias Result = Done
    public var id: String, cols: Int?, rows: Int?
    public init(id: String, cols: Int?, rows: Int?) {
        self.id = id
        self.cols = cols
        self.rows = rows
    }
}
/// The first line `kelp attach` sends. From then on the connection is the session's terminal, with raw bytes both ways
/// (history and output going out, the user's typing coming in) and no JSON-RPC. A paused session wakes at `cols` ×
/// `rows`. An ended session shows what it last printed, and then the connection ends.
public struct SessionStream: InternalMethod {
    public static let name = "session.stream"
    public typealias Result = Done
    public var id: String, cols: Int?, rows: Int?
    public init(id: String, cols: Int? = nil, rows: Int? = nil) {
        self.id = id
        self.cols = cols
        self.rows = rows
    }
}
/// Ends the session.
public struct SessionKill: RPCMethod {
    public static let name = "session.kill"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// Stores an agent's secret in the login keychain, where it is read when the agent starts. Without `value`, the secret
/// is deleted.
public struct AgentSetSecret: InternalMethod {
    public static let name = "agent.setSecret"
    public typealias Result = Done
    public var agent: String, key: String, value: String?
    public init(agent: String, key: String, value: String? = nil) {
        self.agent = agent
        self.key = key
        self.value = value
    }
}

/// Saves how an agent starts (Settings › Agent Catalog) as the agent's file in the agents folder. `manifest` is the
/// whole file, with secrets in it as `agent.setSecret` left them. nil removes the file, so the agent starts as Kelp's
/// preset says again.
public struct AgentSave: InternalMethod {
    public static let name = "agent.save"
    public typealias Result = Done
    public var agent: String, manifest: JSONValue?
    public init(agent: String, manifest: JSONValue? = nil) {
        self.agent = agent
        self.manifest = manifest
    }
}

/// Returns the CPU and memory of each running session's processes.
public struct SessionUsage: RPCMethod {
    public static let name = "session.usage"
    public init() {}
    /// The CPU of a live session (ps's %, summed over the session's processes, where 100 is one core) and its resident
    /// memory.
    public struct Usage: Codable, Sendable, Equatable {
        public var session: String, cpu: Double, memory: Int, processes: Int
        public init(session: String, cpu: Double, memory: Int, processes: Int) {
            self.session = session
            self.cpu = cpu
            self.memory = memory
            self.processes = processes
        }
    }
    public typealias Result = [Usage]
}
/// Returns the program a shell runs in the foreground, which closing the shell would stop, or null.
public struct SessionBusy: RPCMethod {
    public static let name = "session.busy"
    public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}
/// Returns the commands the session's agent ran with its shell tool, oldest first. The last 100 are kept while the
/// background service runs.
public struct SessionCommands: RPCMethod {
    public static let name = "session.commands"
    public typealias Result = [AgentCommand]
    public var id: String
    public init(id: String) { self.id = id }
}
/// Returns the last `bytes` the session printed, as text.
public struct SessionRead: RPCMethod {
    public static let name = "session.read"
    public typealias Result = String
    public var id: String, bytes: Int?
    public init(id: String, bytes: Int? = nil) {
        self.id = id
        self.bytes = bytes
    }
}
/// The same as session.read, with room for "Copy Context".
public struct SessionContext: RPCMethod {
    public static let name = "session.context"
    public typealias Result = String
    public var id: String, bytes: Int?
    public init(id: String, bytes: Int? = nil) {
        self.id = id
        self.bytes = bytes
    }
}
/// Clears the session's unread mark.
public struct SessionMarkRead: RPCMethod {
    public static let name = "session.markRead"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// Schedules the daemon to type "continue" into a session that a plan limit stopped, so Kelp's window can be closed by
/// then. nil cancels it.
public struct SessionContinueAt: InternalMethod {
    public static let name = "session.continueAt"
    public typealias Result = Done
    public var id: String, at: Date?
    public init(id: String, at: Date?) {
        self.id = id
        self.at = at
    }
}

/// Sets the session's unread mark.
public struct SessionMarkUnread: RPCMethod {
    public static let name = "session.markUnread"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// Returns a one-line recap of what a finished Claude Code agent did and what is left. It comes from a fork of the
/// conversation, which leaves the conversation as it was, and is kept as the session's summary. nil when the agent
/// isn't Claude Code, or couldn't be asked.
public struct SessionRecap: InternalMethod {
    public static let name = "session.recap"
    public typealias Result = String?
    public static var timeout: TimeInterval? { 100 }
    public var id: String
    public init(id: String) { self.id = id }
}

/// Reads the agent's last message from its transcript.
public struct SessionLastReply: RPCMethod {
    public static let name = "session.lastReply"
    public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}

/// Returns a running session's status and where it came from: a hook, the program's own report, or the screen. nil
/// when the session isn't running.
public struct SessionWhy: RPCMethod {
    public static let name = "session.why"
    public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}

/// Returns the statuses a session went through and the hooks it heard, oldest first, one per line. The trail is kept
/// after the session ended, and is empty when nothing has happened yet.
public struct SessionTrail: RPCMethod {
    public static let name = "session.trail"
    public typealias Result = String
    public var id: String
    public init(id: String) { self.id = id }
}

/// Moves a session to another workspace of the same folder. The agent goes on as it was, and its tab moves there.
public struct SessionMove: RPCMethod {
    public static let name = "session.move"
    public typealias Result = Done
    public var id: String, worktreeId: String
    public init(id: String, worktreeId: String) {
        self.id = id
        self.worktreeId = worktreeId
    }
}

/// Sets the session's title. An empty title names the session from its task again.
public struct SessionRename: RPCMethod {
    public static let name = "session.rename"
    public typealias Result = Done
    public var id: String, title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Returns how full the agent's conversation is, from Claude Code transcripts. nil when that isn't known.
public struct SessionContextWindow: RPCMethod {
    public static let name = "session.contextWindow"
    public struct Usage: Codable, Sendable, Equatable {
        public var used: Int, window: Int
        /// When the prompt cache goes cold, judged by what the last reply wrote to it. nil when that isn't known.
        public var cacheUntil: Date?
        public init(used: Int, window: Int, cacheUntil: Date? = nil) {
            self.used = used
            self.window = window
            self.cacheUntil = cacheUntil
        }
    }
    public typealias Result = Usage?
    public var id: String
    public init(id: String) { self.id = id }
}

/// Returns what fills a Claude Code conversation's context since its last compaction. That is the base it starts with
/// (the system prompt, tools, CLAUDE.md and skills of the first request) and the parts after it. The parts are
/// estimated from the transcript and scaled so that base plus parts equals the tokens the last reply counted. nil when
/// that isn't known (other agents, or no reply yet).
public struct SessionContextParts: InternalMethod {
    public static let name = "session.contextParts"
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// What the Read tool returned, by file.
        case files
        /// What Bash and the other tools printed, by command or tool.
        case commands
        /// The agent's replies (and what it wrote with Edit or Write), your messages, and Claude Code's notes to the
        /// agent.
        case conversation
        /// The summary /compact kept of the conversation before it.
        case summary
    }
    public struct Item: Codable, Sendable, Equatable {
        /// A label such as "payment.ts", "npm test" or "its replies", seen `count` times ("npm test ×38", "your 9
        /// messages").
        public var label: String, tokens: Int, count: Int
        public init(label: String, tokens: Int, count: Int = 1) {
            self.label = label
            self.tokens = tokens
            self.count = count
        }
    }
    public struct Part: Codable, Sendable, Equatable {
        public var kind: Kind, tokens: Int
        /// The three biggest items, biggest first. `more` counts the items besides them.
        public var top: [Item], more: Int
        public init(kind: Kind, tokens: Int, top: [Item], more: Int) {
            self.kind = kind
            self.tokens = tokens
            self.top = top
            self.more = more
        }
    }
    public struct Parts: Codable, Sendable, Equatable {
        /// `parts` are in Kind's order, with the empty ones left out.
        public var base: Int, parts: [Part]
        /// The base as the agent itself splits it, when it says (Claude Code's /context).
        public var setup: Setup?
        public init(base: Int, parts: [Part], setup: Setup? = nil) {
            self.base = base
            self.parts = parts
            self.setup = setup
        }
    }
    /// What every request starts with, as Claude Code's /context counts it: system prompt, tools, MCP, memory files,
    /// skills… (`parts`, in /context's order, summing to the base). Some groups list their biggest items
    /// ("CLAUDE.md 4k").
    public struct Setup: Codable, Sendable, Equatable {
        public struct Group: Codable, Sendable, Equatable {
            /// The group's name as Claude Code gives it: "System prompt", "Memory files".
            public var label: String, tokens: Int
            public var top: [Item], more: Int
            public init(label: String, tokens: Int, top: [Item] = [], more: Int = 0) {
                self.label = label
                self.tokens = tokens
                self.top = top
                self.more = more
            }
        }
        public var parts: [Group]
        /// Tools that Claude Code loads only when one is used ("MCP tools (deferred)"), so they aren't in the
        /// context.
        public var deferred: [Item]
        /// The tokens kept free for compacting. The conversation compacts by itself before it reaches them.
        public var buffer: Int
        public init(parts: [Group], deferred: [Item] = [], buffer: Int = 0) {
            self.parts = parts
            self.deferred = deferred
            self.buffer = buffer
        }
    }
    public typealias Result = Parts?
    public var id: String
    public init(id: String) { self.id = id }
}

/// Reports what a program in the session says it is doing (`kelp report`, the same as writing OSC 7501 itself). `state`
/// is idle, working, blocked, done, error or clear. `message` shows on the card of the session's row, and `progress`
/// (0–100) shows on its mark while it works.
public struct SessionReport: RPCMethod {
    public static let name = "session.report"
    public typealias Result = Done
    public var id: String, state: String, message: String?, progress: Int?, kind: String?
    public init(id: String, state: String, message: String? = nil, progress: Int? = nil, kind: String? = nil) {
        self.id = id
        self.state = state
        self.message = message
        self.progress = progress
        self.kind = kind
    }
}

/// herdr's agent report, which fx sends to `HERDR_SOCKET_PATH` (kelpd's socket for it). `pane_id` names the session,
/// and `state` is idle, working or blocked. herdr's other calls (`pane.rename`…) aren't Kelp's, so they are
/// refused.
public struct PaneReportAgent: InternalMethod {
    public static let name = "pane.report_agent"
    public typealias Result = Done
    public var paneId: String, state: String
    enum CodingKeys: String, CodingKey { case paneId = "pane_id", state }
    public init(paneId: String, state: String) {
        self.paneId = paneId
        self.state = state
    }
}
