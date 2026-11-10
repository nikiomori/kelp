import Foundation

// addons.*: what agents get besides the prompt (skills, MCP servers, instruction files): read from the agents' own
// files and from what a chat reported at its start. Kelp writes none of the agents' files.

/// A skill, an MCP server or an instruction file an agent gets.
public struct Addon: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case skill, server, instructions
        /// A plugin of the agent's, as a whole: listed only while it's off (on, its skills and servers are the rows).
        case plugin
    }
    /// Who brought it: Kelp (its own skills), the person (their folders and settings), the project (its files), a
    /// plugin of the agent's, the agent's account (claude.ai's skills and connectors), or the agent itself (built in).
    public enum Source: String, Codable, Sendable, CaseIterable {
        case kelp, yours, project, plugin, account, agent
    }

    public var kind: Kind, name: String, source: Source
    public var id: String { "\(kind.rawValue):\(name)" }
    /// Its own line about itself (a skill's description).
    public var about: String?
    /// Where it comes from, as the person would name it: a folder ("~/.agents/skills"), a file, a plugin, "claude.ai".
    public var origin: String?
    /// The ids of the agents that get it.
    public var agents: [String]
    /// In the chat asked about: true when it loaded there; nil when no chat's own record says.
    public var loaded: Bool?
    /// Why it doesn't work, in a few words ("Doesn't start: no such file").
    public var problem: String?
    /// A server that waits for a sign-in: it offers nothing else until then.
    public var signIn: Bool
    /// What it adds to every request of the chat, estimated from the chat's own record; nil when unknown.
    public var tokens: Int?
    /// Other places the same one sits in (a second copy of a skill's folder).
    public var copies: [String]
    /// What `addons.set` takes to switch it for the project: its own ("skill:tabbit", "server:claude_ai_Gmail",
    /// "kelp:kelp-vm") or its plugin's ("plugin:sales", which switches all of that plugin's). nil: nothing switches it.
    public var key: String?
    /// Off for this project: a chat started from now on doesn't get it.
    public var off: Bool
    /// The agents among `agents` that get it whatever the switch says: they have no way to leave it out of one chat.
    public var fixed: [String]

    public init(
        kind: Kind, name: String, source: Source, about: String? = nil, origin: String? = nil, agents: [String] = [],
        loaded: Bool? = nil, problem: String? = nil, signIn: Bool = false, tokens: Int? = nil, copies: [String] = [],
        key: String? = nil, off: Bool = false, fixed: [String] = []
    ) {
        self.kind = kind
        self.name = name
        self.source = source
        self.about = about
        self.origin = origin
        self.agents = agents
        self.loaded = loaded
        self.problem = problem
        self.signIn = signIn
        self.tokens = tokens
        self.copies = copies
        self.key = key
        self.off = off
        self.fixed = fixed
    }
}

/// What `addons.list` answers. `chat`: the list is what that chat reported at its start (Claude Code writes it down);
/// false when it's only what the files say a new chat would get.
public struct Addons: Codable, Sendable, Equatable {
    public var items: [Addon], chat: Bool
    public init(items: [Addon], chat: Bool) {
        self.items = items
        self.chat = chat
    }
}

/// The skills, MCP servers and instruction files of the workspace's agents; with `session`, what that chat loaded.
public struct AddonsList: RPCMethod {
    public static let name = "addons.list"
    public typealias Result = Addons
    public var worktreeId: String, session: String?
    public init(worktreeId: String, session: String? = nil) {
        self.worktreeId = worktreeId
        self.session = session
    }
}

/// Switches a skill, a server or a plugin (`Addon.key`) for the workspace's project. Chats started from then on get
/// it or don't; one that runs keeps what it started with. Nothing of the agents' own is written: the choice is Kelp's
/// (UI state `addons.off.<repo>`) and reaches an agent on its command line.
public struct AddonsSet: InternalMethod {
    public static let name = "addons.set"
    public typealias Result = Done
    public var worktreeId: String, key: String, on: Bool
    public init(worktreeId: String, key: String, on: Bool) {
        self.worktreeId = worktreeId
        self.key = key
        self.on = on
    }
}
