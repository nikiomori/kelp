import Core
import Foundation

/// `addons.list`'s rows: what a chat's own record says it loaded, laid over what the files name. The record knows
/// what really loaded and what it weighs; the files know whose a skill is, where it sits and which agents read it.
public enum AddonList {
    /// The agents in the order rows show them: the one most chats run first.
    static let order = ["claude", "codex", "cursor", "pi", "copilot", "kimi", "opencode", "grok"]

    /// `loaded`: a Claude Code chat's record, nil without one. `kelp`: the names of Kelp's own skills on disk.
    /// `kept`: the servers in Kelp's own file, which it hands to Claude Code and Codex.
    public static func build(
        loaded: ClaudeLoaded?, files: AddonFiles, cwd: String, kelp: [String], kept: [String] = []
    ) -> [Addon] {
        let onDisk = files.skills(cwd: cwd)
        let own = files.servers(cwd: cwd).filter { !kept.contains($0.name) }
        let named =
            own
            + kept.map { AddonFiles.Server(name: $0, file: Addon.kept, agents: ["claude", "codex"], project: false) }
        var items: [Addon] = []
        if let loaded {
            items += loaded.skills.map { skill(of: $0, onDisk: onDisk, files: files) }
            items += loaded.tools.sorted { $0.key < $1.key }.map { server(of: $0.key, $0.value, loaded, named) }
            items += loaded.failed.sorted { $0.key < $1.key }.map { failed($0.key, $0.value, named) }
            items += loaded.files.map { file in
                Addon(
                    kind: .instructions, name: (file.path as NSString).lastPathComponent,
                    source: Paths.inside(file.path, cwd) ? .project : .yours, origin: files.tilde(file.path),
                    agents: ["claude"], loaded: true, tokens: ClaudeLoaded.tokens(file.chars))
            }
        } else {
            items += kelp.map {
                Addon(kind: .skill, name: $0, source: .kelp, origin: "Kelp", agents: ["claude"], key: "kelp:\($0)")
            }
        }
        // What only the files know of: a skill or a server of another agent's, an instruction file Claude Code skips.
        let seen = Set(items.map(\.id))
        items += merged(onDisk, files: files).filter { !seen.contains($0.id) }
        items += named.filter { !seen.contains("server:\($0.name)") }.map {
            Addon(
                kind: .server, name: $0.name, source: $0.project ? .project : .yours, origin: $0.file,
                agents: $0.agents, key: "server:\($0.name)")
        }
        for file in files.instructions(cwd: cwd) where !seen.contains("instructions:\(file.name)") {
            items.append(
                Addon(
                    kind: .instructions, name: file.name, source: .project, agents: file.agents,
                    tokens: ClaudeLoaded.tokens(file.chars)))
        }
        return items
    }

    /// A listed skill: "plugin:name" is a plugin's (Kelp's own are plugins named kelp-…, claude.ai's sit under
    /// anthropic-skills), a bare name is a folder's, and one in no folder came with the agent.
    static func skill(of listed: ClaudeLoaded.Skill, onDisk: [AddonFiles.Skill], files: AddonFiles) -> Addon {
        var item = Addon(
            kind: .skill, name: listed.name, source: .agent, about: listed.about, agents: ["claude"], loaded: true,
            tokens: ClaudeLoaded.tokens(listed.chars), key: "skill:\(listed.name)")
        let parts = listed.name.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            item.name = parts[1]
            item.origin = parts[0]
            item.source = parts[0].hasPrefix("kelp-") ? .kelp : parts[0] == "anthropic-skills" ? .account : .plugin
            if item.source == .kelp { (item.origin, item.key) = ("Kelp", "kelp:\(parts[0])") }
            if item.source == .account { item.origin = "claude.ai" }
            // Two plugins may bring a skill of one name: the plugin stays in it. A plugin's skills go with the plugin.
            if item.source == .plugin { (item.name, item.key) = (listed.name, "plugin:\(parts[0])") }
            return item
        }
        guard let found = merged(onDisk.filter { $0.name == listed.name }, files: files).first else {
            item.origin = "Claude Code"
            return item
        }
        item.source = found.source
        item.origin = found.origin
        item.copies = found.copies
        item.agents = found.agents.contains("claude") ? found.agents : ["claude"] + found.agents
        return item
    }

    /// A server by its name in tool names: "claude_ai_Gmail" is the account's connector, "plugin_<plugin>_<server>" a
    /// plugin's, one the files name is the person's or the project's, and the rest came with the agent.
    static func server(_ name: String) -> (name: String, source: Addon.Source, origin: String?) {
        if name.hasPrefix("claude_ai_") {
            return (name.dropFirst(10).replacingOccurrences(of: "_", with: " "), .account, "claude.ai")
        }
        for prefix in ["plugin_", "plugin:"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count).split(separator: prefix.last ?? "_", maxSplits: 1).map(String.init)
            return (rest.last ?? name, .plugin, rest.first)
        }
        return (name, .agent, "Claude Code")
    }

    private static func server(
        of key: String, _ tools: [String], _ loaded: ClaudeLoaded, _ named: [AddonFiles.Server]
    ) -> Addon {
        var item = base(key, named)
        item.loaded = true
        item.signIn = Set(tools).isSubset(of: ["authenticate", "complete_authentication"])
        // Its tools wait until one is used: a request carries their names, and the server's own instructions.
        let chars =
            tools.reduce(0) { $0 + key.count + $1.count + 8 } + (loaded.notes[key] ?? loaded.notes[item.name] ?? 0)
        item.tokens = ClaudeLoaded.tokens(chars)
        return item
    }

    private static func failed(_ key: String, _ error: String, _ named: [AddonFiles.Server]) -> Addon {
        var item = base(key, named)
        item.loaded = false
        item.problem = problem(error)
        return item
    }

    /// `key`: the server as tool names spell it ("plugin_data_definite"; a failed one comes as "plugin:data:definite").
    private static func base(_ key: String, _ named: [AddonFiles.Server]) -> Addon {
        let (name, source, origin) = server(key)
        let off = "server:" + key.replacingOccurrences(of: ":", with: "_")
        guard source == .agent, let file = named.first(where: { $0.name == key }) else {
            return Addon(kind: .server, name: name, source: source, origin: origin, agents: ["claude"], key: off)
        }
        return Addon(
            kind: .server, name: name, source: file.project ? .project : .yours, origin: file.file,
            agents: file.agents, key: off)
    }

    /// An error as one short line: "ENOENT: no such file or directory, posix_spawn '/Applications/…'" says the program
    /// isn't there.
    static func problem(_ error: String) -> String {
        if error.contains("ENOENT") { return "Doesn’t start: its program isn’t there" }
        let first = error.split(separator: "\n").first.map(String.init) ?? error
        return first.isEmpty ? "Doesn’t start" : "Doesn’t start: " + first.prefix(80)
    }

    /// The folders as skills: one a name, the agents of every folder that holds it (a link counts as its target), and
    /// a second real folder of the same name as a copy.
    static func merged(_ skills: [AddonFiles.Skill], files: AddonFiles) -> [Addon] {
        var names: [String] = [], byName: [String: [AddonFiles.Skill]] = [:]
        for skill in skills {
            if byName[skill.name] == nil { names.append(skill.name) }
            byName[skill.name, default: []].append(skill)
        }
        return names.compactMap { name in
            guard let all = byName[name], let first = all.first else { return nil }
            let home = all.first { $0.real == $0.path } ?? first
            let reading = Set(all.flatMap(\.agents))
            let agents = order.filter(reading.contains) + reading.subtracting(order).sorted()
            let copies = Set(all.map(\.real)).subtracting([home.real]).sorted().map(files.tilde)
            return Addon(
                kind: .skill, name: name, source: home.project ? .project : .yours, about: home.about,
                origin: files.tilde((home.real as NSString).deletingLastPathComponent), agents: agents, copies: copies,
                key: "skill:\(name)")
        }
    }
}
