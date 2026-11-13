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

    /// `origin` of a server Kelp keeps in its own file: one `addons.remove` takes away.
    public static let kept = "Kelp"

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
    /// The file to open for it: a skill's SKILL.md, an instruction file, the settings file a server is named in.
    public var path: String?
    /// The whole of what went wrong, as the agent reported it (`problem` is its short form).
    public var error: String?
    /// The plugin it came with, by the id the agent installed it under ("sales@synced"): what its own
    /// `plugin uninstall` takes.
    public var plugin: String?
    /// An instruction file's size against what its agents read of it, and what it names that's gone.
    public var check: InstructionCheck?

    public init(
        kind: Kind, name: String, source: Source, about: String? = nil, origin: String? = nil, agents: [String] = [],
        loaded: Bool? = nil, problem: String? = nil, signIn: Bool = false, tokens: Int? = nil, copies: [String] = [],
        key: String? = nil, off: Bool = false, fixed: [String] = [], path: String? = nil, error: String? = nil,
        plugin: String? = nil, check: InstructionCheck? = nil
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
        self.path = path
        self.error = error
        self.plugin = plugin
        self.check = check
    }
}

/// How an instruction file holds up. Agents read it before every chat: what's stale there is paid for in every request,
/// and what's past their limit they never see.
public struct InstructionCheck: Codable, Sendable, Equatable {
    public var lines: Int, bytes: Int
    /// Where its agents stop reading (Claude Code: MEMORY.md's first 200 lines or 25 000 bytes; Codex: 32 KiB of
    /// AGENTS.md), or the length their makers advise (200 lines); nil: none.
    public var maxLines: Int?, maxBytes: Int?
    /// Lines past where its agents stop reading: never seen.
    public var cut: Int
    /// Paths it names, in folders of the project that exist, that aren't there (a memory index: its memories' too).
    public var dead: [String]
    /// A memory index: its lines whose memory file is missing, and memory files no line of it names.
    public var missing: Int, unlisted: Int
    /// Its copy from before the last Tidy Up (a memory index: its whole folder), while Kelp keeps one.
    public var before: String?

    public init(
        lines: Int, bytes: Int, maxLines: Int? = nil, maxBytes: Int? = nil, cut: Int = 0, dead: [String] = [],
        missing: Int = 0, unlisted: Int = 0, before: String? = nil
    ) {
        self.lines = lines
        self.bytes = bytes
        self.maxLines = maxLines
        self.maxBytes = maxBytes
        self.cut = cut
        self.dead = dead
        self.missing = missing
        self.unlisted = unlisted
        self.before = before
    }

    /// How full it is against its limit, the fuller measure (1 = at the limit); nil without one.
    public var share: Double? {
        let parts = [maxLines.map { Double(lines) / Double($0) }, maxBytes.map { Double(bytes) / Double($0) }]
        return parts.compactMap { $0 }.max()
    }
    /// Worth a look: lines not read, near its limit, or naming what's gone.
    public var needsLook: Bool {
        cut > 0 || (share ?? 0) >= Self.near || !dead.isEmpty || missing > 0 || unlisted > 0
    }
    /// From here on a file is near its limit: tidied before agents start losing lines.
    public static let near = 0.8
}

/// What `addons.list` answers. `chat`: the list is what that chat reported at its start (Claude Code writes it down);
/// false when it's only what the files say a new chat would get.
public struct Addons: Codable, Sendable, Equatable {
    public var items: [Addon], chat: Bool
    /// What the chat started with that isn't there any more (a skill deleted, a server taken out of the settings): it
    /// keeps them until it restarts.
    public var gone: [String]?
    public init(items: [Addon], chat: Bool, gone: [String]? = nil) {
        self.items = items
        self.chat = chat
        self.gone = gone
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

/// An MCP server as Kelp keeps it and as the agents' own files spell it (`mcpServers`): a program it starts
/// (`command`, `args`, `env`) or an address it calls (`url`, `headers`).
public struct ServerEntry: Codable, Sendable, Equatable {
    public var command: String?, args: [String]?, env: [String: String]?
    public var url: String?, headers: [String: String]?
    public init(
        command: String? = nil, args: [String]? = nil, env: [String: String]? = nil, url: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }

    /// What someone pasted, read: a JSON entry (bare, under its name, or a whole `{"mcpServers": {…}}`), an address,
    /// or a command line ("npx -y pkg", with `KEY=value` words before it as its environment). nil when it's none.
    public static func parse(_ pasted: String) -> (name: String, entry: ServerEntry)? {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("{") { return json(text) }
        if let url = URL(string: text), let host = url.host, ["http", "https"].contains(url.scheme ?? "") {
            let words = host.split(separator: ".").filter { !["www", "mcp", "api"].contains($0) }
            return (name(String(words.first ?? "server")), ServerEntry(url: text))
        }
        var words = text.split(separator: " ").map(String.init), env: [String: String] = [:]
        while let first = words.first, let equals = first.firstIndex(of: "="), !first.hasPrefix("-"),
            first[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        {
            env[String(first[..<equals])] = String(first[first.index(after: equals)...])
            words.removeFirst()
        }
        guard let command = words.first else { return nil }
        // Named by its package: the last word that isn't a flag ("@upstash/context7-mcp" → "context7").
        let package = words.dropFirst().last { !$0.hasPrefix("-") } ?? command
        let entry = ServerEntry(command: command, args: Array(words.dropFirst()), env: env.isEmpty ? nil : env)
        return (name(package), entry)
    }

    private static func json(_ text: String) -> (name: String, entry: ServerEntry)? {
        // Typed half-way it isn't JSON yet: no server, and nothing to report.
        func read<T: Decodable>(_ body: () throws -> T) -> T? {
            do { return try body() } catch { return nil }
        }
        guard let value = read({ try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }) else { return nil }
        func entry(_ value: JSONValue?) -> ServerEntry? {
            guard let value, let entry = read({ try value.decode(ServerEntry.self) }),
                entry.command != nil || entry.url != nil
            else { return nil }
            return entry
        }
        if let bare = entry(value) { return (name(bare.args?.last ?? bare.url ?? bare.command ?? "server"), bare) }
        guard case .object(let fields) = value["mcpServers"] ?? value, let first = fields.keys.sorted().first,
            let named = entry(fields[first])
        else { return nil }
        return (first, named)
    }

    /// "@upstash/context7-mcp@latest" → "context7": a short name the agents take (letters, digits, - and _).
    static func name(_ from: String) -> String {
        var base = (from.split(separator: "/").last.map(String.init) ?? from)
        if let at = base.firstIndex(of: "@"), at != base.startIndex { base = String(base[..<at]) }
        for affix in ["mcp-server-", "server-", "mcp-"] where base.hasPrefix(affix) { base.removeFirst(affix.count) }
        for affix in ["-mcp-server", "-mcp", "-server"] where base.hasSuffix(affix) { base.removeLast(affix.count) }
        let clean = base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return String(clean).trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }
}

/// Adds an MCP server for every agent Kelp can hand one to: kept in Kelp's own `mcp.json` (all projects) or, with
/// `project`, in the project's `.mcp.json`, which goes to the team with the repository. One of the same name is
/// replaced. With `from`, the entry is the one that agent's own file has under `name` ("claude", "codex").
public struct AddonsAdd: InternalMethod {
    public static let name = "addons.add"
    public typealias Result = Done
    public var worktreeId: String, name: String, entry: ServerEntry?, project: Bool, from: String?
    public init(worktreeId: String, name: String, entry: ServerEntry?, project: Bool = false, from: String? = nil) {
        self.worktreeId = worktreeId
        self.name = name
        self.entry = entry
        self.project = project
        self.from = from
    }
}

/// Takes a server added through Kelp away again (`Addon.key`): from Kelp's own file, or from the project's `.mcp.json`.
public struct AddonsRemove: InternalMethod {
    public static let name = "addons.remove"
    public typealias Result = Done
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// A server's entry as its file has it (`Addon.key`): Kelp's own, the project's, or the one in an agent's own settings.
/// For editing it and copying it out. It may hold what the server signs in with: the user's only.
public struct AddonsEntry: InternalMethod {
    public static let name = "addons.entry"
    public typealias Result = ServerEntry
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// Tidy Up: copies the instruction files at `paths` (a memory index: its whole folder) into Kelp's home, puts the
/// `tidyInstructions` recipe beside them, and answers the one-line prompt that sends an agent to it. Kelp writes none
/// of the files themselves: the agent does, and reports before it changes anything.
public struct AddonsTidy: InternalMethod {
    public static let name = "addons.tidy"
    public typealias Result = String
    public var worktreeId: String, paths: [String]
    public init(worktreeId: String, paths: [String]) {
        self.worktreeId = worktreeId
        self.paths = paths
    }
}

/// Moves one of the person's own skills (`Addon.key`, in their folders or the project's) to the Trash, with the links
/// that point at it.
public struct AddonsTrash: InternalMethod {
    public static let name = "addons.trash"
    public typealias Result = Done
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// Gives a skill only some agents read (`Addon.key`) to the rest: a link to its folder in the folder the others read
/// (`~/.agents/skills` and Claude Code's own; the project's two for a project's skill).
public struct AddonsLink: InternalMethod {
    public static let name = "addons.link"
    public typealias Result = Done
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// Adds skills: a new one named `name` (a SKILL.md to fill in), or with `source` those of a folder or a git
/// repository (every folder in it that holds a SKILL.md). They go into the shared folder (`~/.agents/skills`, or the
/// project's `.agents/skills` with `project`) with a link in Claude Code's. Returns the SKILL.md files, new first.
public struct AddonsInstall: InternalMethod {
    public static let name = "addons.install"
    public typealias Result = [String]
    public static var timeout: TimeInterval? { 120 }
    public var worktreeId: String, name: String?, source: String?, project: Bool
    public init(worktreeId: String, name: String? = nil, source: String? = nil, project: Bool = false) {
        self.worktreeId = worktreeId
        self.name = name
        self.source = source
        self.project = project
    }
}
