import Core
import Foundation

/// The skills and MCP servers the agents' own files name, and the folders the agents share: read only. Which agent
/// reads which folder is each agent's documented behaviour (2026-11): `~/.agents/skills` is the shared standard,
/// Claude Code reads only its own, Cursor, opencode and Grok read Claude Code's too, and Copilot a project's
/// `.claude/skills` and CLAUDE.md.
public struct AddonFiles: Sendable {
    public var home: URL, claude: URL, codex: URL

    public init(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()), claude: URL = AgentHome.root("claude"),
        codex: URL = AgentHome.root("codex")
    ) {
        self.home = home
        self.claude = claude
        self.codex = codex
    }

    static let sharedReaders = ["codex", "cursor", "pi", "copilot", "kimi", "opencode", "grok"]
    static let claudeReaders = ["claude", "cursor", "opencode", "grok"]
    static let claudeProjectReaders = claudeReaders + ["copilot"]

    /// A skill folder: its SKILL.md's name and description, where it is, and where it really is (a link's target).
    public struct Skill: Sendable, Equatable {
        public var name: String, about: String, path: String, real: String, agents: [String], project: Bool
    }
    public struct Server: Sendable, Equatable {
        /// `file`: where it's named, as the person would say it ("~/.claude.json"); `path`: that file, to open.
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
            (project.appendingPathComponent(".claude/skills"), Self.claudeProjectReaders, true)
        ]
        return places.flatMap { dir, agents, inProject in
            Self.folders(dir).compactMap { folder -> Skill? in
                guard let text = Self.text(folder.appendingPathComponent("SKILL.md"))
                else { return nil }
                // By its folder's name, as the agents list it (a SKILL.md may name itself otherwise).
                return Skill(
                    name: folder.lastPathComponent, about: Self.frontmatter(text)["description"] ?? "",
                    path: folder.path, real: folder.resolvingSymlinksInPath().path, agents: agents, project: inProject)
            }
        }
    }

    /// The MCP servers the files name for a chat in `cwd`: Claude Code's (its own file and the project's `.mcp.json`)
    /// and Codex's. Names only: what they run and their secrets stay unread.
    public func servers(cwd: String) -> [Server] {
        var out: [Server] = []
        let own = claude.appendingPathComponent(".claude.json")   // a profile's folder holds its own
        let file = FileManager.default.fileExists(atPath: own.path) ? own : home.appendingPathComponent(".claude.json")
        if let root = Self.json(file) {
            let mine = (root["mcpServers"] as? [String: Any] ?? [:]).keys
            let here = ((root["projects"] as? [String: Any])?[cwd] as? [String: Any])?["mcpServers"] as? [String: Any]
            for name in Set(mine).union((here ?? [:]).keys) {
                out.append(
                    Server(name: name, file: tilde(file.path), agents: ["claude"], project: false, path: file.path))
            }
        }
        let shared = URL(fileURLWithPath: cwd).appendingPathComponent(".mcp.json")
        for name in (Self.json(shared)?["mcpServers"] as? [String: Any] ?? [:]).keys {
            out.append(
                Server(name: name, file: ".mcp.json", agents: ["claude", "copilot"], project: true, path: shared.path))
        }
        let config = codex.appendingPathComponent("config.toml")
        for name in Self.codexServers(Self.text(config) ?? "") {
            out.append(
                Server(name: name, file: tilde(config.path), agents: ["codex"], project: false, path: config.path))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The instruction files in the project's folder, with who reads each: Claude Code takes CLAUDE.md and falls back
    /// to AGENTS.md only without one; the others read AGENTS.md.
    public func instructions(cwd: String) -> [(name: String, chars: Int, agents: [String])] {
        func chars(_ name: String) -> Int? {
            Self.text(URL(fileURLWithPath: cwd).appendingPathComponent(name))?.count
        }
        let claudeFile = chars("CLAUDE.md")
        var out: [(String, Int, [String])] = []
        if let claudeFile { out.append(("CLAUDE.md", claudeFile, ["claude", "copilot"])) }
        if let agents = chars("AGENTS.md") {
            out.append(("AGENTS.md", agents, (claudeFile == nil ? ["claude"] : []) + Self.sharedReaders))
        }
        return out
    }

    /// `path` with the home folder as "~".
    public func tilde(_ path: String) -> String {
        Paths.inside(path, home.path) ? "~" + path.dropFirst(home.path.count) : path
    }

    /// The enabled servers of a Codex config: `[mcp_servers.name]` tables without `enabled = false`.
    static func codexServers(_ toml: String) -> [String] {
        var names: [String] = [], off = Set<String>(), current: String?
        for raw in toml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let parts = table.split(separator: ".").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                current = parts.count == 2 && parts[0] == "mcp_servers" ? parts[1] : nil
                if let current { names.append(current) }
            } else if let current, line.replacingOccurrences(of: " ", with: "") == "enabled=false" {
                off.insert(current)
            }
        }
        return names.filter { !off.contains($0) }
    }

    /// The `key: value` lines between a SKILL.md's first two `---`, quotes taken off.
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
