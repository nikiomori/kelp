import Core
import Foundation

/// The switches a project sets with `addons.set`: which rows they turn off, and how each agent is told when a chat
/// starts. Claude Code takes all the switches as settings for one run. Codex takes only the server switches, on its
/// command line. The other agents have no way to leave something out of one chat (`Addon.fixed`).
public enum AddonSwitches {
    /// Returns `items` with each item's switch read from `off`. It also adds a row for every switch that names no
    /// listed item, because an add-on that is off didn't load, so the chat's record doesn't mention it.
    public static func applied(_ off: Set<String>, to items: [Addon]) -> [Addon] {
        var out = items.map { item -> Addon in
            var item = item
            guard let key = item.key else { return item }
            item.off = off.contains(key)
            item.fixed = item.agents.filter { !reaches($0, item.kind) }
            return item
        }
        let listed = Set(out.compactMap(\.key))
        for key in off.subtracting(listed).sorted() {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let kind: Addon.Kind? = ["skill": .skill, "kelp": .skill, "server": .server, "plugin": .plugin][parts[0]]
            guard let kind else { continue }
            let source: Addon.Source = parts[0] == "kelp" ? .kelp : parts[0] == "plugin" ? .plugin : .yours
            var item = Addon(
                kind: kind, name: parts[1], source: source, agents: [Session.claudeAgent], key: key, off: true)
            if kind == .server { (item.name, item.source, item.origin) = AddonList.server(parts[1]) }
            out.append(item)
        }
        return out
    }

    /// Whether Kelp can leave an add-on of `kind` out of a chat that `agent` runs.
    static func reaches(_ agent: String, _ kind: Addon.Kind) -> Bool {
        agent == Session.claudeAgent || (agent == Session.codexAgent && kind == .server)
    }

    /// Turns what is off into Claude Code's settings for one run (checked on 2.1.322). A skill is turned off in
    /// `skillOverrides`, where a claude.ai skill answers to its bare name. A plugin is turned off in `enabledPlugins`
    /// under its installed id (`name@marketplace`, or `name@synced` for claude.ai's plugins). A server is turned off by
    /// a deny rule on its tools. The result is empty when nothing is off.
    public static func claudeSettings(_ off: Set<String>, plugins: [String]) -> [String: JSONValue] {
        var skills: [String: JSONValue] = [:], unplugged: [String: JSONValue] = [:], deny: [JSONValue] = []
        for key in off.sorted() {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "skill":
                skills[parts[1]] = "off"
                if let bare = parts[1].split(separator: ":").last, bare != parts[1] { skills[String(bare)] = "off" }
            case "plugin":
                let ids = plugins.filter { $0.hasPrefix(parts[1] + "@") }
                for id in ids.isEmpty ? [parts[1] + "@synced"] : ids { unplugged[id] = false }
            case "server": deny.append(.string("mcp__" + parts[1]))
            default: break
            }
        }
        var out: [String: JSONValue] = [:]
        if !skills.isEmpty { out["skillOverrides"] = .object(skills) }
        if !unplugged.isEmpty { out["enabledPlugins"] = .object(unplugged) }
        if !deny.isEmpty { out["permissions"] = .object(["deny": .array(deny)]) }
        return out
    }

    /// Turns what is off into Codex arguments (checked on 0.166): `-c mcp_servers.<name>.enabled=false` for each of
    /// Codex's own servers that is off.
    public static func codexArgs(_ off: Set<String>, servers: [String]) -> [String] {
        servers.filter { off.contains("server:\($0)") }.sorted().flatMap { ["-c", "mcp_servers.\($0).enabled=false"] }
    }
}

extension AddonFiles {
    /// Returns the ids of Claude Code's installed plugins. "sales@synced" is never among them, because claude.ai's
    /// plugins aren't installed on this Mac.
    public func claudePlugins() -> [String] {
        let file = claude.appendingPathComponent("plugins/installed_plugins.json")
        let root = Data(contentsIfAny: file).flatMap(JSONL.object)
        return ((root?["plugins"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    /// The names of Codex's own enabled servers.
    public func codexServers() -> [String] {
        Self.codexServers(codexConfig)
    }
}
