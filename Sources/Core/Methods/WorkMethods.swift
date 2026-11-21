import Foundation

/// Where an agent worked: the files it read and edited in its project, the places outside the project it reached
/// (sites, hosts, MCP servers, other folders), and its steps, for one turn or for the whole session. It is read from
/// the agent's conversation (Claude Code's transcript and its subagents', Codex's rollout), and from the agents it
/// started. The inspector's Work panel and the Map tab draw it.
public struct AgentWork: Codable, Sendable, Equatable {
    /// One turn: what was asked, and when.
    public struct Turn: Codable, Sendable, Equatable {
        public var prompt: String, at: Date
        public init(prompt: String, at: Date) {
            self.prompt = prompt
            self.at = at
        }
    }

    /// One agent that worked in the turn: the session's own agent first, then its subagents and the agents it started.
    public struct Agent: Codable, Sendable, Equatable {
        public enum Role: String, Codable, Sendable, CaseIterable { case main, subagent, child }
        public var role: Role
        /// The agent's catalog id for its logo (`claude`, `codex`); a subagent has its parent's.
        public var agent: String
        /// What to call it: the agent's name, or a subagent's kind ("Explore").
        public var name: String
        public var task: String?
        /// The subagent's id, or the started agent's session id.
        public var id: String?
        public init(role: Role, agent: String, name: String, task: String? = nil, id: String? = nil) {
            self.role = role
            self.agent = agent
            self.name = name
            self.task = task
            self.id = id
        }
    }

    /// What kind of thing a place is.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A file in the project. Its name is its path from the project's root.
        case file
        /// A folder in the project that was searched (Grep, Glob, `rg`), not opened.
        case folder
        /// A site, by host only: a URL's path and query can hold tokens.
        case web
        /// A host reached over ssh, scp, rsync, or a Kelp machine.
        case machine
        /// An MCP server, by its name.
        case tool
        /// A package manager that installed or resolved something (brew, npm, pip…).
        case packages
        /// A folder outside the project, shortened to two levels under the home folder.
        case outside
        /// The agent's own folders: the temporary folder, `~/.claude`, `~/.codex`. Shown folded.
        case own
    }

    public struct Place: Codable, Sendable, Equatable {
        public var kind: Kind, name: String
        public var reads = 0, edits = 0
        /// Lines added and removed by edits, as the agent's own edits reported them.
        public var added = 0, removed = 0
        /// Who touched it: indexes into `agents`.
        public var agents: [Int] = []
        /// The git worktree under the project (`.claude/worktrees/<name>`) the agent touched it in: such a path is
        /// folded onto the project's own.
        public var worktree: String?
        /// Changed by a command (the turn's snapshot shows it) with no edit of the agent's own.
        public var byCommand = false
        /// What was done there, as a short phrase: "curl ×6", "brew install".
        public var detail: String?
        public var first: Date?, last: Date?
        public init(kind: Kind, name: String) {
            self.kind = kind
            self.name = name
        }
    }

    /// One step, for the Steps view.
    public struct Step: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case read, search, edit, command, failed, web, tool, ask, spawn, report, other
        }
        public var agent: Int, kind: Kind
        /// The tool's name ("Read", "Bash", "WebFetch").
        public var tool: String
        /// The path, command, host or question, one line.
        public var detail: String
        public var at: Date
        public var added = 0, removed = 0
        /// For `spawn` and `report`, the agent started or reporting back: an index into `agents`.
        public var other: Int?
        public init(agent: Int, kind: Kind, tool: String, detail: String, at: Date) {
            self.agent = agent
            self.kind = kind
            self.tool = tool
            self.detail = detail
            self.at = at
        }
    }

    /// Every turn of the session, oldest first.
    public var turns: [Turn] = []
    /// The turn the places and steps are of (an index into `turns`), or nil for the whole session.
    public var turn: Int?
    public var agents: [Agent] = []
    public var places: [Place] = []
    /// The turn's steps, oldest first. Empty for the whole session.
    public var steps: [Step] = []
    /// Where the agent is now (an index into `places`), while it works.
    public var now: Int?
    /// The project's root as the agent saw it, so a view can tell its paths from others.
    public var root: String?
    public init() {}
}

/// Returns where an agent worked in one turn (`turn`, an index into `AgentWork.turns`; nil for the last) or in the
/// whole session. nil when its conversation can't be read: an agent that keeps none Kelp knows, or a host with no open
/// connection.
public struct SessionWork: InternalMethod {
    public static let name = "session.work"
    public typealias Result = AgentWork?
    public var id: String
    public var turn: Int?
    public var whole: Bool?
    public init(id: String, turn: Int? = nil, whole: Bool? = nil) {
        self.id = id
        self.turn = turn
        self.whole = whole
    }
}

/// An agent's work changed: its conversation, or the conversation of an agent it started, grew. Pushed while someone
/// watches (`WatchTopic.work`), so a view reads `SessionWork` again.
public struct WorkEvent: RPCEvent, Equatable {
    public static let name = "event.work"
    public var session: String
    /// Changes whenever the conversations change.
    public var stamp: String
    public init(session: String, stamp: String) {
        self.session = session
        self.stamp = stamp
    }
}
