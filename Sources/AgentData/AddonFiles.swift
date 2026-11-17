import Core
import Foundation

/// Reads, and never writes, the skills and MCP servers that the agents' own files list, and the skill folders the
/// agents share. Which agent reads which folder follows each agent's documentation (2026-11). `~/.agents/skills` is the
/// shared standard. Claude Code reads only its own folder. Cursor, opencode and Grok also read Claude Code's folder,
/// and Copilot reads a project's `.claude/skills` and CLAUDE.md.
public struct AddonFiles: Sendable {
    public var home: URL, claude: URL, codex: URL, copilot: URL, pi: URL

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()), claude: URL = AgentHome.root(Session.claudeAgent),
        codex: URL = AgentHome.root(Session.codexAgent), copilot: URL = AgentHome.root("copilot"),
        pi: URL = AgentHome.root("pi")
    ) {
        self.home = home
        self.claude = claude
        self.codex = codex
        self.copilot = copilot
        self.pi = pi
    }

    static let sharedReaders = [Session.codexAgent, "cursor", "pi", "copilot", "kimi", "opencode", "grok"]
    static let claudeReaders = [Session.claudeAgent, "cursor", "opencode", "grok"]
    static let claudeProjectReaders = claudeReaders + ["copilot"]

    /// A skill folder: its name, the description from its SKILL.md, its path, and its real path (the target of a link).
    public struct Skill: Sendable, Equatable {
        public var name: String, about: String, path: String, real: String, agents: [String], project: Bool
    }
    public struct Server: Sendable, Equatable {
        /// `file` is the file that lists the server, as a person would write it ("~/.claude.json"). `path` is the full
        /// path of that file, for opening it.
        public var name: String, file: String, agents: [String], project: Bool, path: String?
        public init(name: String, file: String, agents: [String], project: Bool, path: String? = nil) {
            self.name = name
            self.file = file
            self.agents = agents
            self.project = project
            self.path = path
        }
    }

    /// The skill folders of the person and of the project at `cwd`.
    public func skills(cwd: String) -> [Skill] {
        let project = URL(fileURLWithPath: cwd)
        let places: [(URL, [String], Bool)] = [
            (home.appendingPathComponent(".agents/skills"), Self.sharedReaders, false),
            (claude.appendingPathComponent("skills"), Self.claudeReaders, false),
            (project.appendingPathComponent(".agents/skills"), Self.sharedReaders, true),
            (project.appendingPathComponent(".claude/skills"), Self.claudeProjectReaders, true),
            (codex.appendingPathComponent("skills"), [Session.codexAgent], false),
            (copilot.appendingPathComponent("skills"), ["copilot"], false),
            (project.appendingPathComponent(".github/skills"), ["copilot"], true)
        ]
        return places.flatMap { dir, agents, inProject in
            Self.folders(dir).compactMap { folder -> Skill? in
                guard let text = Self.text(folder.appendingPathComponent("SKILL.md"))
                else { return nil }
                // The skill takes its folder's name, as the agents list it, because a SKILL.md may give another name.
                return Skill(
                    name: folder.lastPathComponent, about: Self.frontmatter(text)["description"] ?? "",
                    path: folder.path, real: folder.resolvingSymlinksInPath().path, agents: agents, project: inProject)
            }
        }
    }

    /// Returns the MCP servers that the config files list for a chat in `cwd`: Claude Code's (from its own file and the
    /// project's `.mcp.json`), pi's and Codex's. Only the names are read, so the commands and secrets stay unread.
    public func servers(cwd: String) -> [Server] {
        var out: [Server] = []
        let file = claudeJSON
        if let root = Self.json(file) {
            let mine = (root["mcpServers"] as? [String: Any] ?? [:]).keys
            let here = ((root["projects"] as? [String: Any])?[cwd] as? [String: Any])?["mcpServers"] as? [String: Any]
            for name in Set(mine).union((here ?? [:]).keys) {
                out.append(
                    Server(
                        name: name, file: tilde(file.path), agents: [Session.claudeAgent], project: false,
                        path: file.path))
            }
        }
        let here = URL(fileURLWithPath: cwd), shared = here.appendingPathComponent(".mcp.json")
        for name in (Self.json(shared)?["mcpServers"] as? [String: Any] ?? [:]).keys {
            out.append(
                Server(
                    name: name, file: ".mcp.json", agents: [Session.claudeAgent, "copilot"], project: true,
                    path: shared.path))
        }
        // pi's servers come from mcp.json in pi's folder and the project's .pi/mcp.json, skipping those turned off.
        for (file, project) in [
            (pi.appendingPathComponent("mcp.json"), false), (here.appendingPathComponent(".pi/mcp.json"), true)
        ] {
            for (name, entry) in Self.json(file)?["mcpServers"] as? [String: Any] ?? [:]
            where (entry as? [String: Any])?["enabled"] as? Bool != false {
                out.append(
                    Server(
                        name: name, file: project ? ".pi/mcp.json" : tilde(file.path), agents: ["pi"], project: project,
                        path: file.path))
            }
        }
        let config = codex.appendingPathComponent("config.toml")
        for name in Self.codexServers(codexConfig) {
            out.append(
                Server(
                    name: name, file: tilde(config.path), agents: [Session.codexAgent], project: false,
                    path: config.path))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Returns the instruction files in the project's folder and the agents that read each one. Claude Code reads
    /// CLAUDE.md, and AGENTS.md only when there is no CLAUDE.md. Copilot also reads CLAUDE.md. The others read
    /// AGENTS.md.
    public func instructions(cwd: String) -> [(name: String, chars: Int, agents: [String])] {
        func chars(_ name: String) -> Int? {
            Self.text(URL(fileURLWithPath: cwd).appendingPathComponent(name))?.count
        }
        let claudeFile = chars("CLAUDE.md")
        var out: [(String, Int, [String])] = []
        if let claudeFile { out.append(("CLAUDE.md", claudeFile, [Session.claudeAgent, "copilot"])) }
        if let agents = chars("AGENTS.md") {
            out.append(("AGENTS.md", agents, (claudeFile == nil ? [Session.claudeAgent] : []) + Self.sharedReaders))
        }
        return out
    }

    /// Claude Code's .claude.json: a profile folder's own, else the one in the home folder.
    var claudeJSON: URL {
        let own = claude.appendingPathComponent(".claude.json")
        return FileManager.default.fileExists(atPath: own.path) ? own : home.appendingPathComponent(".claude.json")
    }

    /// The text of Codex's config.toml, empty when there is none.
    var codexConfig: String { Self.text(codex.appendingPathComponent("config.toml")) ?? "" }

    /// Returns `path` with the home folder written as "~".
    public func tilde(_ path: String) -> String {
        Paths.inside(path, home.path) ? "~" + path.dropFirst(home.path.count) : path
    }

    /// Returns the enabled servers in a Codex config, which are the `[mcp_servers.name]` tables without
    /// `enabled = false`.
    static func codexServers(_ toml: String) -> [String] {
        let toml = MiniTOML(toml)
        return toml.names(under: "mcp_servers.").filter { name in
            !toml.pairs.contains { $0.key == "mcp_servers.\(name).enabled" && $0.value as? Bool == false }
        }
    }

    /// Returns the `key: value` lines between the first two `---` lines of a SKILL.md, with quotes taken off.
    static func frontmatter(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return out }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[String(line[..<colon])] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return out
    }

    private static func folders(_ dir: URL) -> [URL] {
        return FileManager.default.items(in: dir).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted {
            $0.path < $1.path
        }
    }

    private static func text(_ url: URL) -> String? {
        Data(contentsIfAny: url).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        Data(contentsIfAny: url).flatMap(JSONL.object)
    }
}
