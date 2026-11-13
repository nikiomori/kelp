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
        list(loaded: loaded, files: files, cwd: cwd, kelp: kelp, kept: kept).items
    }

    /// `build`, and what the chat's record names that isn't there any more (`gone`): the record is from the chat's
    /// start, and for what lives in files (the person's skills, the project's, their servers) the files are what's true
    /// now. `builtIn`: the skills Claude Code brings itself, when known (`ClaudeBuiltIns`).
    public static func list(
        loaded: ClaudeLoaded?, files: AddonFiles, cwd: String, kelp: [String], kept: [String] = [],
        builtIn: Set<String>? = nil, kelpHome: URL? = nil
    ) -> (items: [Addon], gone: [String]) {
        var gone: [String] = []
        let plugins = loaded == nil ? [:] : files.plugins()
        let kelpSkills = kelpHome?.appendingPathComponent("agent-skills")
        let keptFile = kelpHome?.appendingPathComponent("mcp.json").path
        let onDisk = files.skills(cwd: cwd)
        let own = files.servers(cwd: cwd).filter { !kept.contains($0.name) }
        let named =
            own
            + kept.map {
                AddonFiles.Server(
                    name: $0, file: Addon.kept, agents: ["claude", "codex"], project: false, path: keptFile)
            }
        var items: [Addon] = []
        if let loaded {
            // A bare name in no folder is Claude Code's own or one deleted since. Unknown which are its own, the
            // listing's order says: the person's and the project's come first, so one before the last still on disk
            // was theirs.
            let bare = loaded.skills.map(\.name).filter { !$0.contains(":") }
            let lastHere = bare.lastIndex { name in onDisk.contains { $0.name == name } } ?? -1
            for listed in loaded.skills {
                var item = skill(of: listed, onDisk: onDisk, files: files)
                locate(&item, listed.name, plugins: plugins, kelp: kelpSkills, files: files)
                let own = builtIn?.contains(listed.name) ?? ((bare.firstIndex(of: listed.name) ?? .max) > lastHere)
                if item.source == .agent, !listed.name.contains(":"), !own {
                    gone.append(listed.name)
                } else {
                    items.append(item)
                }
            }
            let servers =
                loaded.tools.sorted { $0.key < $1.key }.map { server(of: $0.key, $0.value, loaded, named) }
                + loaded.failed.sorted { $0.key < $1.key }.map { failed($0.key, $0.value, named) }
            // A server no file names and no plugin or account brought: Claude Code's own ("claude-in-chrome"), or one
            // taken out of the settings since.
            for var item in servers {
                if item.source == .plugin { item.plugin = item.origin.flatMap { plugins[$0]?.id } }
                if item.source == .agent, !item.name.hasPrefix("claude"), item.name != "ide" {
                    gone.append(item.name)
                } else {
                    items.append(item)
                }
            }
            items += loaded.files.map { file in
                Addon(
                    kind: .instructions, name: (file.path as NSString).lastPathComponent,
                    source: Paths.inside(file.path, cwd) ? .project : .yours, origin: files.tilde(file.path),
                    agents: ["claude"], loaded: true, tokens: ClaudeLoaded.tokens(file.chars), path: file.path)
            }
        } else {
            items += kelp.map {
                Addon(
                    kind: .skill, name: $0, source: .kelp, origin: "Kelp", agents: ["claude"], key: "kelp:\($0)",
                    path: kelpSkills?.appendingPathComponent("\($0)/skills/\($0)/SKILL.md").path)
            }
        }
        // What only the files know of: a skill or a server of another agent's, an instruction file Claude Code skips.
        let seen = Set(items.map(\.id))
        items += merged(onDisk, files: files).filter { !seen.contains($0.id) }
        items += named.filter { !seen.contains("server:\($0.name)") }.map {
            Addon(
                kind: .server, name: $0.name, source: $0.project ? .project : .yours, origin: $0.file,
                agents: $0.agents, key: "server:\($0.name)", path: $0.path)
        }
        for file in files.instructions(cwd: cwd) where !seen.contains("instructions:\(file.name)") {
            items.append(
                Addon(
                    kind: .instructions, name: file.name, source: .project, agents: file.agents,
                    tokens: ClaudeLoaded.tokens(file.chars),
                    path: URL(fileURLWithPath: cwd).appendingPathComponent(file.name).path))
        }
        if let memory = memory(cwd: cwd, files: files), !items.contains(where: { $0.id == memory.id }) {
            items.append(memory)
        }
        return (joined(items), gone)
    }

    /// Claude Code's memory of the project, which a new chat there gets, when no chat's record says so: its index,
    /// of which Claude Code reads the first 25 000 bytes.
    static func memory(cwd: String, files: AddonFiles) -> Addon? {
        let folder = ClaudeHistory.folder(cwd: cwd, root: files.claude.appendingPathComponent("projects"))
        let index = folder.appendingPathComponent("memory/MEMORY.md")
        guard let data = FileManager.default.contents(atPath: index.path) else { return nil }
        let chars = String(decoding: data.prefix(InstructionChecks.memoryBytes), as: UTF8.self).count
        return Addon(
            kind: .instructions, name: "MEMORY.md", source: .yours,
            origin: files.tilde(index.deletingLastPathComponent().path), agents: ["claude"],
            tokens: ClaudeLoaded.tokens(chars), path: index.path)
    }

    /// One instruction file listed under two names (CLAUDE.md a link to AGENTS.md) is one row: the file's own name,
    /// every agent that reads it, and which name links to it.
    static func joined(_ items: [Addon]) -> [Addon] {
        var out: [Addon] = [], at: [String: Int] = [:]
        for item in items {
            guard item.kind == .instructions, let path = item.path else {
                out.append(item)
                continue
            }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard let index = at[real] else {
                at[real] = out.count
                out.append(item)
                continue
            }
            var kept = out[index], link = item
            // The file itself stays, under its own name (a path's folders may be links too: /tmp is /private/tmp).
            if (real as NSString).lastPathComponent == item.name { swap(&kept, &link) }
            kept.agents = (kept.agents + link.agents.filter { !kept.agents.contains($0) }).sorted {
                (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count)
            }
            kept.about = "\(link.name) links here"
            kept.tokens = [kept.tokens, link.tokens].compactMap { $0 }.max()
            out[index] = kept
        }
        return out
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
        item.path = found.path
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
        item.error = error
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
            agents: file.agents, key: off, path: file.path)
    }

    /// Where a listed skill that came with a plugin, with Kelp or from the account is on disk, and its plugin's id.
    private static func locate(
        _ item: inout Addon, _ listed: String, plugins: [String: AddonFiles.Plugin], kelp: URL?, files: AddonFiles
    ) {
        let parts = listed.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        var file: URL?
        switch item.source {
        case .plugin:
            item.plugin = plugins[parts[0]]?.id
            file = plugins[parts[0]].map { $0.dir.appendingPathComponent("skills/\(parts[1])/SKILL.md") }
        case .kelp: file = kelp?.appendingPathComponent("\(parts[0])/skills/\(parts[1])/SKILL.md")
        case .account:
            let synced = files.claude.appendingPathComponent("skills/synced")
            file = FileManager.default.items(in: synced).map { $0.appendingPathComponent("\(parts[1])/SKILL.md") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        default: break
        }
        if let file, FileManager.default.fileExists(atPath: file.path) { item.path = file.path }
    }

    /// An error as one short line: "ENOENT: no such file or directory, posix_spawn '/Applications/…'" says the program
    /// isn't there.
    /// "Dynamic Client Registration rejected (HTTP 403): <html…" is a sign-in refused; anything else is its first
    /// sentence, without the address's scheme. The whole text stays in `Addon.error`.
    static func problem(_ error: String) -> String {
        if error.contains("ENOENT") { return "Doesn’t start: its program isn’t there" }
        if error.contains("Registration"), let code = error.range(of: #"\(HTTP \d+\)"#, options: .regularExpression) {
            return "Sign-in refused \(error[code])"
        }
        let line = error.split(separator: "\n").first.map(String.init) ?? error
        let first = (line.components(separatedBy: ". ").first ?? line).replacingOccurrences(of: "https://", with: "")
        return first.isEmpty ? "Doesn’t start" : String(first.prefix(70))
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
                key: "skill:\(name)", path: home.real + "/SKILL.md")
        }
    }
}
