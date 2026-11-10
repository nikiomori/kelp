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
/// → {turn, hasBase}: the files its last turn changed and how long it took; null when the session isn't running.
public struct SessionTurn: RPCMethod {
    public static let name = "session.turn"
    public var id: String
    public init(id: String) { self.id = id }
    /// One turn of the agent: what it changed by the time it stopped, and how long it worked.
    public struct Turn: Codable, Sendable, Equatable {
        public struct File: Codable, Sendable, Equatable {
            public var path: String, added: Int, removed: Int
            public init(path: String, added: Int, removed: Int) {
                self.path = path
                self.added = added
                self.removed = removed
            }
        }
        public var files: [File], seconds: Double
        public init(files: [File], seconds: Double) {
            self.files = files
            self.seconds = seconds
        }
    }
    public struct Info: Codable, Sendable, Equatable {
        public var turn: Turn?, hasBase: Bool
        public init(turn: Turn?, hasBase: Bool) {
            self.turn = turn
            self.hasBase = hasBase
        }
    }
    public typealias Result = Info?
}
/// The session's turns, the newest first (the last 20): how its folder was as each began, with the prompt that started
/// it. None for a remote project's, where no snapshots are taken.
public struct SessionTurns: RPCMethod {
    public static let name = "session.turns"
    public typealias Result = [Mark]
    public var id: String
    public init(id: String) { self.id = id }
    /// A turn's start: `tree` is the folder then (a snapshot in the project's git, which git's cleanup may take after
    /// two weeks), `head` its HEAD then.
    public struct Mark: Codable, Sendable, Equatable, Identifiable {
        public var id: String, session: String, tree: String, head: String?, folder: String, prompt: String, at: Date
        public init(
            id: String = UUID().uuidString, session: String, tree: String, head: String?, folder: String,
            prompt: String,
            at: Date = Date()
        ) {
            self.id = id
            self.session = session
            self.tree = tree
            self.head = head
            self.folder = folder
            self.prompt = prompt
            self.at = at
        }
    }
}

/// A turn of the agent's undone: its folder put back as it was when `turn` began. Without `apply`, what would go back
/// and the folder's state now; with it, done only while the folder is still that `state`, answering with the state after
/// (for `session.turnRedo`). Refused while the agent works,
/// after commits since the turn began, and with another agent in the folder. `.env` files stay as they are.
public struct SessionTurnUndo: RPCMethod {
    public static let name = "session.turnUndo"
    public typealias Result = Plan
    public var id: String, turn: String, apply: Bool?, state: String?
    public init(id: String, turn: String, apply: Bool? = nil, state: String? = nil) {
        self.id = id
        self.turn = turn
        self.apply = apply
        self.state = state
    }
    public struct Plan: Codable, Sendable, Equatable {
        public var files: [String], state: String
        public init(files: [String], state: String) {
            self.files = files
            self.state = state
        }
    }
}

/// The last `session.turnUndo` taken back: the folder as it was before it, while it is still `state` (the Plan that
/// undo answered with). `turn` is the one that was undone.
public struct SessionTurnRedo: RPCMethod {
    public static let name = "session.turnRedo"
    public typealias Result = Done
    public var id: String, turn: String, state: String
    public init(id: String, turn: String, state: String) {
        self.id = id
        self.turn = turn
        self.state = state
    }
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
