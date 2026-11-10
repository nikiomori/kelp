import Foundation

// session.*: the sessions in a workspace, what they printed and did, their input, their turns.

/// All sessions, or those of workspace `worktreeId`.
public struct SessionList: RPCMethod {
    public static let name = "session.list"
    public typealias Result = [Session]
    public var worktreeId: String?
    public init(worktreeId: String? = nil) { self.worktreeId = worktreeId }
}
/// → {history}: what it printed so far (base64); then `event.output` for this connection.
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
/// The user's keys (`base64`), or `text` as it is.
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
/// `text`, then Enter (unless `enter` is false) a beat later so a TUI takes it as a submit.
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
/// The size of its terminal.
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
/// `kelp attach`'s first line: from here on the connection is the session's terminal, raw bytes both ways (its history
/// and output out, the user's typing in), and no JSON-RPC. A paused session wakes at `cols` × `rows`; an ended one shows
/// what it last printed, then the connection ends.
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
/// `answer`: allow | deny, to the menu on screen → false when there is none. `question`: what the answer was given to (the
/// session's summary a banner showed) → false too once the agent asks something else, or several things at once.
public struct SessionChoose: RPCMethod {
    public static let name = "session.choose"
    public typealias Result = Bool
    public var id: String, answer: String, question: String?
    public init(id: String, answer: String, question: String? = nil) {
        self.id = id
        self.answer = answer
        self.question = question
    }
}
/// A permission question's hook (Claude Code's PermissionRequest) waits here for Allow or Deny given in Kelp: "allow",
/// "deny", or nil once it was answered in the terminal or ten minutes passed. The agent's own menu stays on screen
/// meanwhile (Claude Code shows it while the hook runs), so the terminal can answer too.
public struct SessionPermissionWait: InternalMethod {
    public static let name = "session.permissionWait"
    public typealias Result = String?
    public static var timeout: TimeInterval? { 620 }
    public var id: String
    public init(id: String) { self.id = id }
}
/// Kept in the login keychain, read when the agent starts. No `value`: deleted.
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

/// Settings › Agent Catalog: how an agent starts, kept as its file in the agents folder. `manifest` is the whole file
/// (secrets in it as `agent.setSecret` left them); nil removes it, and the agent starts as Kelp's preset says again.
public struct AgentSave: InternalMethod {
    public static let name = "agent.save"
    public typealias Result = Done
    public var agent: String, manifest: JSONValue?
    public init(agent: String, manifest: JSONValue? = nil) {
        self.agent = agent
        self.manifest = manifest
    }
}

/// CPU and memory of each running session's processes.
public struct SessionUsage: RPCMethod {
    public static let name = "session.usage"
    public init() {}
    /// CPU (ps's %, summed over the session's processes; 100 = one core) and resident memory of a live session.
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
/// The program a shell runs in the foreground (closing it would stop that), or null.
public struct SessionBusy: RPCMethod {
    public static let name = "session.busy"
    public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}
/// The commands its agent ran with its shell tool, oldest first: the last 100, kept while the background service runs.
public struct SessionCommands: RPCMethod {
    public static let name = "session.commands"
    public typealias Result = [AgentCommand]
    public var id: String
    public init(id: String) { self.id = id }
}
/// The last `bytes` it printed, as text.
public struct SessionRead: RPCMethod {
    public static let name = "session.read"
    public typealias Result = String
    public var id: String, bytes: Int?
    public init(id: String, bytes: Int? = nil) {
        self.id = id
        self.bytes = bytes
    }
}
/// session.read with room for "Copy Context".
public struct SessionContext: RPCMethod {
    public static let name = "session.context"
    public typealias Result = String
    public var id: String, bytes: Int?
    public init(id: String, bytes: Int? = nil) {
        self.id = id
        self.bytes = bytes
    }
}
/// Clears its unread mark.
public struct SessionMarkRead: RPCMethod {
    public static let name = "session.markRead"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// "continue" typed into a session a plan limit stopped, by the daemon, so Kelp's window can be closed by then. nil takes it back.
public struct SessionContinueAt: InternalMethod {
    public static let name = "session.continueAt"
    public typealias Result = Done
    public var id: String, at: Date?
    public init(id: String, at: Date?) {
        self.id = id
        self.at = at
    }
}

/// Sets its unread mark.
public struct SessionMarkUnread: RPCMethod {
    public static let name = "session.markUnread"
    public typealias Result = Done
    public var id: String
    public init(id: String) { self.id = id }
}
/// What a finished Claude Code agent did and what's left, in a line, from a fork of its conversation that leaves the
/// conversation as it was; kept as its summary. nil: not Claude Code, or it couldn't be asked.
public struct SessionRecap: InternalMethod {
    public static let name = "session.recap"
    public typealias Result = String?
    public static var timeout: TimeInterval? { 100 }
    public var id: String
    public init(id: String) { self.id = id }
}

/// The agent's last message, from its transcript.
public struct SessionLastReply: RPCMethod {
    public static let name = "session.lastReply"
    public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}

/// A running session's status and where it came from: a hook, the program's own report, the screen. nil: it isn't running.
public struct SessionWhy: RPCMethod {
    public static let name = "session.why"
    public typealias Result = String?
    public var id: String
    public init(id: String) { self.id = id }
}

/// What a session's status went through and the hooks it heard, oldest first, a line each. Kept after it ended; empty when
/// nothing happened yet.
public struct SessionTrail: RPCMethod {
    public static let name = "session.trail"
    public typealias Result = String
    public var id: String
    public init(id: String) { self.id = id }
}

/// To another screen of the same folder: the agent goes on as it was, its tab goes there.
public struct SessionMove: RPCMethod {
    public static let name = "session.move"
    public typealias Result = Done
    public var id: String, worktreeId: String
    public init(id: String, worktreeId: String) {
        self.id = id
        self.worktreeId = worktreeId
    }
}

/// Sets its title; an empty one names the session from its task again.
public struct SessionRename: RPCMethod {
    public static let name = "session.rename"
    public typealias Result = Done
    public var id: String, title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// How full the agent's conversation is (Claude Code transcripts); nil when that isn't known.
public struct SessionContextWindow: RPCMethod {
    public static let name = "session.contextWindow"
    public struct Usage: Codable, Sendable, Equatable {
        public var used: Int, window: Int
        /// When the prompt cache goes cold, by what the last reply wrote to it; nil when that isn't known.
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

/// What fills a Claude Code conversation's context since its last compaction: the base it starts with (system prompt,
/// tools, CLAUDE.md, skills: the first request) and the parts after it, estimated from the transcript and scaled so that
/// base + parts make the tokens the last reply counted. nil when that isn't known (other agents, no reply yet).
public struct SessionContextParts: InternalMethod {
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
        public init(label: String, tokens: Int, count: Int = 1) {
            self.label = label
            self.tokens = tokens
            self.count = count
        }
    }
    public struct Part: Codable, Sendable, Equatable {
        public var kind: Kind, tokens: Int
        /// The biggest three, biggest first; `more` items besides them.
        public var top: [Item], more: Int
        public init(kind: Kind, tokens: Int, top: [Item], more: Int) {
            self.kind = kind
            self.tokens = tokens
            self.top = top
            self.more = more
        }
    }
    public struct Parts: Codable, Sendable, Equatable {
        /// In Kind's order, the empty ones left out.
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
    /// skills… (`parts`, in its order, summing to the base), with the biggest items of some ("CLAUDE.md 4k").
    public struct Setup: Codable, Sendable, Equatable {
        public struct Group: Codable, Sendable, Equatable {
            /// As Claude Code names it: "System prompt", "Memory files".
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
        /// Tools it loads only when one is used ("MCP tools (deferred)"): not in the context.
        public var deferred: [Item]
        /// Kept free for compacting: the conversation compacts by itself before it reaches this.
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

/// What a program in the session says it's doing (`kelp report`; the same as writing OSC 7501 itself): `state` is idle,
/// working, blocked, done, error or clear; `message` shows on its row's card, `progress` (0–100) on its mark while it works.
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

/// herdr's agent report, which fx sends to `HERDR_SOCKET_PATH` (kelpd's socket for it): `pane_id` is the session, `state`
/// idle, working or blocked. herdr's other calls (`pane.rename`…) aren't Kelp's: refused.
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
