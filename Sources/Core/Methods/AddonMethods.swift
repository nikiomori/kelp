import Foundation

// The addons.* methods: what agents get besides the prompt (skills, MCP servers, instruction files). It is read from
// the agents' own files and from what a chat reported at its start. Kelp writes none of the agents' files.

/// A skill, an MCP server or an instruction file an agent gets.
public struct Addon: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case skill, server, instructions
        /// One of the agent's plugins, as a whole. It is listed only while it is off. While it is on, its skills and
        /// servers are listed as rows instead.
        case plugin
    }
    /// Who brought the item: Kelp (its own skills), the person (their folders and settings), the project (its files),
    /// one of the agent's plugins, the agent's account (claude.ai's skills and connectors), or the agent itself (built
    /// in).
    public enum Source: String, Codable, Sendable, CaseIterable {
        case kelp, yours, project, plugin, account, agent
    }

    /// The `origin` of a server that Kelp keeps in its own file, which `addons.remove` can take away.
    public static let kept = "Kelp"

    public var kind: Kind, name: String, source: Source
    public var id: String { "\(kind.rawValue):\(name)" }
    /// The item's own one-line description of itself (a skill's description).
    public var about: String?
    /// Where the item comes from, as the person would name it: a folder ("~/.agents/skills"), a file, a plugin, or
    /// "claude.ai".
    public var origin: String?
    /// The ids of the agents that get the item.
    public var agents: [String]
    /// True when the item loaded in the chat that was asked about. nil when no chat's own record says.
    public var loaded: Bool?
    /// Why the item doesn't work, in a few words ("Doesn't start: no such file").
    public var problem: String?
    /// True for a server that waits for a sign-in. It offers nothing else until then.
    public var signIn: Bool
    /// The tokens the item adds to every request of the chat, estimated from the chat's own record. nil when unknown.
    public var tokens: Int?
    /// Other places where the same item also sits (a second copy of a skill's folder).
    public var copies: [String]
    /// The key that `addons.set` takes to switch this item for the project. It is the item's own key ("skill:tabbit",
    /// "server:claude_ai_Gmail", "kelp:kelp-vm") or its plugin's key ("plugin:sales", which switches everything in that
    /// plugin). nil when nothing can switch it.
    public var key: String?
    /// True when the item is off for this project, so a chat started from now on doesn't get it.
    public var off: Bool
    /// The agents among `agents` that get the item whatever the switch says, because they have no way to leave it out
    /// of one chat.
    public var fixed: [String]
    /// The file to open for the item: a skill's SKILL.md, an instruction file, or the settings file a server is named
    /// in.
    public var path: String?
    /// The full error as the agent reported it. `problem` is its short form.
    public var error: String?
    /// The plugin the item came with, by the id the agent installed it under ("sales@synced"). This is the id that the
    /// agent's own `plugin uninstall` takes.
    public var plugin: String?
    /// For an instruction file, its size compared with how much its agents read, and the things it names that are
    /// gone.
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

/// How an instruction file holds up. Agents read it before every chat, so anything stale in it is paid for in every
/// request, and anything past their limit they never see.
public struct InstructionCheck: Codable, Sendable, Equatable {
    public var lines: Int, bytes: Int
    /// Where the agents stop reading the file (Claude Code reads the first 200 lines or 25 000 bytes of MEMORY.md, and
    /// Codex reads 32 KiB of AGENTS.md), or the length their makers advise (200 lines). nil when there is no such
    /// limit.
    public var maxLines: Int?, maxBytes: Int?
    /// The number of lines past the point where the agents stop reading, which they never see.
    public var cut: Int
    /// Paths the file names, in folders of the project that exist, that aren't there. For a memory index, the paths in
    /// its memories count too.
    public var dead: [String]
    /// For a memory index, the number of lines whose memory file is missing, and of memory files that no line names.
    public var missing: Int, unlisted: Int
    /// Kelp's copy of the file from before the last Tidy Up (for a memory index, its whole folder), while Kelp keeps
    /// one.
    public var before: String?
    /// How many tokens an agent reads of the file now. A chat that started before the file changed still holds what it
    /// read then.
    public var tokens: Int?

    public init(
        lines: Int, bytes: Int, maxLines: Int? = nil, maxBytes: Int? = nil, cut: Int = 0, dead: [String] = [],
        missing: Int = 0, unlisted: Int = 0, before: String? = nil, tokens: Int? = nil
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
        self.tokens = tokens
    }

    /// How full the file is against its limit, by whichever measure is fuller (1 means at the limit). nil when there is
    /// no limit.
    public var share: Double? {
        let parts = [maxLines.map { Double(lines) / Double($0) }, maxBytes.map { Double(bytes) / Double($0) }]
        return parts.compactMap { $0 }.max()
    }
    /// True when the file is worth a look: it has lines that aren't read, it is near its limit, or it names things that
    /// are gone.
    public var needsLook: Bool {
        cut > 0 || (share ?? 0) >= Self.near || !dead.isEmpty || missing > 0 || unlisted > 0
    }
    /// The share at which a file counts as near its limit, so it is tidied before agents start losing lines.
    public static let near = 0.8
}

/// The answer to `addons.list`. `chat` is true when the list is what that chat reported at its start (Claude Code
/// writes it down), and false when it is only what the files say a new chat would get.
public struct Addons: Codable, Sendable, Equatable {
    public var items: [Addon], chat: Bool
    /// What the chat started with that isn't there any more (a skill deleted, a server taken out of the settings). The
    /// chat keeps these until it restarts.
    public var gone: [String]?
    /// The workspace's Tidy Up that waits for review. It goes away once it is kept or undone (`addons.tidyEnd`), or
    /// when it is a day old.
    public var tidied: Tidied?
    public init(items: [Addon], chat: Bool, gone: [String]? = nil, tidied: Tidied? = nil) {
        self.items = items
        self.chat = chat
        self.gone = gone
        self.tidied = tidied
    }
}

/// A Tidy Up's result: how many tokens of the files every chat read before it and reads now, and how many of the files
/// differ from Kelp's copies.
public struct Tidied: Codable, Sendable, Equatable {
    public var tokensBefore: Int, tokensNow: Int, changed: Int
    public init(tokensBefore: Int, tokensNow: Int, changed: Int) {
        self.tokensBefore = tokensBefore
        self.tokensNow = tokensNow
        self.changed = changed
    }
}

/// Lists the skills, MCP servers and instruction files of the workspace's agents. With `session`, it lists what that
/// chat loaded.
public struct AddonsList: RPCMethod {
    public static let name = "addons.list"
    public typealias Result = Addons
    public var worktreeId: String, session: String?
    public init(worktreeId: String, session: String? = nil) {
        self.worktreeId = worktreeId
        self.session = session
    }
}

/// Switches a skill, a server or a plugin (`Addon.key`) on or off for the workspace's project. Chats started from then
/// on follow the switch, and a chat that runs keeps what it started with. None of the agents' own files is written,
/// because the choice is Kelp's (UI state `addons.off.<repo>`) and reaches an agent on its command line.
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

/// An MCP server as Kelp keeps it and as the agents' own files spell it (`mcpServers`). It is either a program the
/// agent starts (`command`, `args`, `env`) or an address it calls (`url`, `headers`).
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

    /// Reads what someone pasted: a JSON entry (bare, under its name, or a whole `{"mcpServers": {…}}`), an address, or
    /// a command line ("npx -y pkg", with `KEY=value` words before it as its environment). nil when it is none of
    /// these.
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
        // Name the server after its package, the last word that isn't a flag ("@upstash/context7-mcp" → "context7").
        let package = words.dropFirst().last { !$0.hasPrefix("-") } ?? command
        let entry = ServerEntry(command: command, args: Array(words.dropFirst()), env: env.isEmpty ? nil : env)
        return (name(package), entry)
    }

    private static func json(_ text: String) -> (name: String, entry: ServerEntry)? {
        // Text typed half-way isn't JSON yet, so there is no server and nothing to report.
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

    /// Turns "@upstash/context7-mcp@latest" into "context7", a short name the agents accept (letters, digits, - and
    /// _).
    static func name(_ from: String) -> String {
        var base = (from.split(separator: "/").last.map(String.init) ?? from)
        if let at = base.firstIndex(of: "@"), at != base.startIndex { base = String(base[..<at]) }
        for affix in ["mcp-server-", "server-", "mcp-"] where base.hasPrefix(affix) { base.removeFirst(affix.count) }
        for affix in ["-mcp-server", "-mcp", "-server"] where base.hasSuffix(affix) { base.removeLast(affix.count) }
        let clean = base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return String(clean).trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }
}

/// Adds an MCP server for every agent Kelp can hand one to. It is kept in Kelp's own `mcp.json` (for all projects) or,
/// with `project`, in the project's `.mcp.json`, which goes to the team with the repository. A server of the same name
/// is replaced. With `from`, the entry is copied from what that agent's own file has under `name` ("claude", "codex").
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

/// Removes a server that was added through Kelp (`Addon.key`), from Kelp's own file or from the project's `.mcp.json`.
public struct AddonsRemove: InternalMethod {
    public static let name = "addons.remove"
    public typealias Result = Done
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// Returns a server's entry as its file has it (`Addon.key`), whether Kelp's own file, the project's, or the agent's
/// own settings. It is used for editing the entry and copying it out. The entry may hold the server's sign-in secrets,
/// so only the user may read it.
public struct AddonsEntry: InternalMethod {
    public static let name = "addons.entry"
    public typealias Result = ServerEntry
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// Tidy Up: copies the instruction files at `paths` (for a memory index, its whole folder) into Kelp's home, puts the
/// `tidyInstructions` recipe beside them, and answers with the one-line prompt that sends an agent to the recipe. Kelp
/// writes none of the files themselves. The agent does, and it reports before it changes anything.
public struct AddonsTidy: InternalMethod {
    public static let name = "addons.tidy"
    public typealias Result = String
    public var worktreeId: String, paths: [String]
    public init(worktreeId: String, paths: [String]) {
        self.worktreeId = worktreeId
        self.paths = paths
    }
}

/// Ends the workspace's Tidy Up. With `undo`, every file is put back from Kelp's copies, and the files as they were are
/// kept beside them. Without it, the changes stay. Either way the result leaves the panel.
public struct AddonsTidyEnd: InternalMethod {
    public static let name = "addons.tidyEnd"
    public typealias Result = Done
    public var worktreeId: String, undo: Bool
    public init(worktreeId: String, undo: Bool) {
        self.worktreeId = worktreeId
        self.undo = undo
    }
}

/// Moves one of the person's own skills (`Addon.key`, in their folders or the project's) to the Trash, together with
/// the links that point at it.
public struct AddonsTrash: InternalMethod {
    public static let name = "addons.trash"
    public typealias Result = Done
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// Gives a skill that only some agents read (`Addon.key`) to the other agents too. It puts a link to the skill's folder
/// in the folder the others read (`~/.agents/skills` and Claude Code's own, or the project's two for a project's
/// skill).
public struct AddonsLink: InternalMethod {
    public static let name = "addons.link"
    public typealias Result = Done
    public var worktreeId: String, key: String
    public init(worktreeId: String, key: String) {
        self.worktreeId = worktreeId
        self.key = key
    }
}

/// Adds skills: a new skill named `name` (a SKILL.md to fill in), or, with `source`, the skills of a folder or a git
/// repository (every folder in it that holds a SKILL.md). They go into the shared folder (`~/.agents/skills`, or the
/// project's `.agents/skills` with `project`), with a link in Claude Code's folder. Returns the SKILL.md files, new
/// ones first.
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
