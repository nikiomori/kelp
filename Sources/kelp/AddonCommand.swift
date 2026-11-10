import Core
import Foundation

extension Main {
    static let addonUsage = """
        mcp list | add <command|address|JSON> [--name n] [--project] | remove|on|off <name>
        skill list | on|off <name>
        """

    /// `mcp <action>` and `skill <action>`: what this workspace's agents get besides the prompt (`addons.*`). `list`
    /// with KELP_SESSION says what that chat loaded. Adding, removing and switching are the user's: Kelp refuses an
    /// agent that tries (it would be handing itself tools).
    static func addons(_ kind: Addon.Kind, _ sub: String?, _ c: RPCClient) async throws {
        let worktree = try await currentWorktree(c)
        let word = kind == .server ? "server" : "skill"
        switch sub {
        case "list":
            let chat = ProcessInfo.processInfo.environment["KELP_SESSION"]
            let all = try await c.call(AddonsList(worktreeId: worktree.id, session: chat))
            let rows = all.items.filter { $0.kind == kind }
            guard !rows.isEmpty else { return print("No \(word)s here.") }
            print(all.chat ? "What this chat loaded:" : "What a new chat here gets:")
            print(
                table(
                    ["name", "from", "agents", "state"],
                    rows.map { [$0.name, $0.origin ?? $0.source.rawValue, $0.agents.joined(separator: " "), state($0)] }
                ))
        case "add" where kind == .server:
            guard let found = ServerEntry.parse(args.joined(separator: " ")) else {
                fail("kelp mcp add <command, address or JSON> [--name n] [--project]")
            }
            let name = flag("--name") ?? found.name
            _ = try await c.call(
                AddonsAdd(worktreeId: worktree.id, name: name, entry: found.entry, project: has("--project")))
            print("Added \(name): new Claude Code and Codex chats get it.")
        case "remove" where kind == .server:
            guard let name = args.first else { fail("kelp mcp remove <name>") }
            _ = try await c.call(AddonsRemove(worktreeId: worktree.id, key: "server:\(name)"))
            print("Removed \(name).")
        case "on", "off":
            guard let name = args.first else { fail("kelp \(kind == .server ? "mcp" : "skill") \(sub ?? "") <name>") }
            let all = try await c.call(AddonsList(worktreeId: worktree.id)).items
            // By the name the list shows, or by the key itself ("plugin:sales").
            let key = all.first { $0.kind == kind && $0.name == name }?.key ?? (name.contains(":") ? name : nil)
            guard let key else { fail("No \(word) named \(name) here: kelp \(kind == .server ? "mcp" : "skill") list") }
            _ = try await c.call(AddonsSet(worktreeId: worktree.id, key: key, on: sub == "on"))
            print("\(name) is \(sub ?? "") in this project: chats started from now on follow it.")
        default: print(addonUsage)
        }
    }

    private static func state(_ addon: Addon) -> String {
        if let problem = addon.problem { return problem }
        if addon.off { return "off here" }
        if addon.signIn { return "needs a sign-in" }
        return addon.loaded == false ? "not loaded" : "on"
    }
}
