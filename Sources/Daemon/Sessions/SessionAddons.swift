import AgentData
import Agents
import Core
import Foundation

/// A project's switches for skills, MCP servers and plugins (`addons.set`), and how a chat that starts is told: the
/// choice is Kelp's own (UI state `addons.off.<repo>`), and reaches the agent on its command line, for that run only.
extension SessionSetup {
    static func addonsOffKey(_ repo: String) -> String { "addons.off.\(repo)" }

    /// What's off in the workspace's project, with the project's id; nothing for a folder in no project.
    func addonsOff(worktreeId: String?) -> (repo: String?, off: Set<String>) {
        let repo = worktreeId.flatMap { id in Log.store.attempt("the workspace \(id)") { try store.worktree(id) } ?? nil
        }?.repoId
        guard let repo else { return (nil, []) }
        let key = Self.addonsOffKey(repo)
        let saved = Log.store.attempt("UI state \(key)") { try store.uiState(prefix: key)[key] } ?? nil
        return (repo, Set((saved?.array ?? []).compactMap(\.string)))
    }

    func setAddon(_ key: String, on: Bool, worktreeId: String) throws {
        let repo = try store.worktree(named: worktreeId).repoId
        var off = addonsOff(worktreeId: worktreeId).off
        if on { off.remove(key) } else { off.insert(key) }
        try store.setUIState(Self.addonsOffKey(repo), off.isEmpty ? nil : .array(off.sorted().map(JSONValue.string)))
    }

    /// The settings file a chat of `manifest`'s starts with: Kelp's hooks, and for Claude Code in a project with
    /// something off, that too, in a file of the project's own. One file: a second `--settings` would replace the first.
    func settingsFile(_ manifest: AgentManifest, worktreeId: String?) throws -> URL {
        let plain = hooksDir(manifest).appendingPathExtension("json")
        let (repo, off) = manifest.id == "claude" ? addonsOff(worktreeId: worktreeId) : (nil, [])
        let extra = AddonSwitches.claudeSettings(off, plugins: AddonFiles().claudePlugins())
        guard let repo, !extra.isEmpty,
            case .object(var all) = try JSONDecoder().decode(JSONValue.self, from: Data(Hooks.settingsJSON().utf8))
        else {
            try Hooks.writeSettings(to: plain)
            return plain
        }
        all.merge(extra) { _, ours in ours }
        let file = root.appendingPathComponent("hooks-\(manifest.id)-\(repo).json")
        try JSONEncoder().encode(JSONValue.object(all)).write(to: file, options: .atomic)
        return file
    }

    /// `argv` with the settings file after `flag`: added to a new chat's; a restart's, which carries the one it had,
    /// gets today's (the project's switches may have changed since).
    func withSettings(
        _ argv: [String], flag: String, manifest: AgentManifest, worktreeId: String?, fresh: Bool
    ) throws -> [String] {
        let file = try settingsFile(manifest, worktreeId: worktreeId).path
        if fresh { return argv + [flag, file] }
        var out = argv
        for index in out.indices.dropLast() where out[index] == flag {
            let old = URL(fileURLWithPath: out[index + 1])
            if Paths.inside(old.path, root.path), old.lastPathComponent.hasPrefix("hooks-\(manifest.id)") {
                out[index + 1] = file
            }
        }
        return out
    }

    /// Kelp's own servers (`addons.add`): for every project, handed to the agents that take one at a start.
    var serversFile: URL { root.appendingPathComponent("mcp.json") }

    /// Kelp's servers a chat in the workspace starts with: all but what's off in its project.
    /// A project's `.mcp.json` isn't among them: a branch can bring one, and the agent that reads it asks first.
    func handedServers(worktreeId: String?) -> [String: ServerEntry] {
        let off = addonsOff(worktreeId: worktreeId).off
        return ServerFiles.read(serversFile).filter { !off.contains("server:\($0.key)") }
    }

    /// A Claude Code's `argv` with Kelp's servers file, when it holds any (what's off is denied in its settings).
    func withServers(_ argv: [String], flag: String) -> [String] {
        var out: [String] = [], index = 0
        while index < argv.count {
            if argv[index] == flag, index + 1 < argv.count, argv[index + 1] == serversFile.path {
                index += 2
                continue
            }
            out.append(argv[index])
            index += 1
        }
        return ServerFiles.read(serversFile).isEmpty ? out : out + [flag, serversFile.path]
    }

    /// What Kelp's servers need of a Codex chat's environment (`ServerFiles.codex`): what they sign in with.
    func codexEnvironment(worktreeId: String?) -> [String: String] {
        ServerFiles.codex(handedServers(worktreeId: worktreeId)).environment
    }

    /// A Codex's `argv` with its own servers that are off here left out and Kelp's handed over, right after the program.
    /// Limit: a `-c mcp_servers.…` the person typed themselves is taken for Kelp's at a restart.
    func withCodexSwitches(_ argv: [String], worktreeId: String?) -> [String] {
        var out: [String] = [], index = 0
        while index < argv.count {
            if argv[index] == "-c", index + 1 < argv.count, argv[index + 1].hasPrefix("mcp_servers.") {
                index += 2
                continue
            }
            out.append(argv[index])
            index += 1
        }
        let off = addonsOff(worktreeId: worktreeId).off, own = AddonFiles().codexServers()
        guard !out.isEmpty else { return out }
        // One Codex has itself stays its own: Kelp's of the same name isn't laid over it.
        let handed = handedServers(worktreeId: worktreeId).filter { !own.contains($0.key) }
        out.insert(contentsOf: AddonSwitches.codexArgs(off, servers: own) + ServerFiles.codex(handed).args, at: 1)
        return out
    }
}
