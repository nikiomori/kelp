import AgentData
import Core
import Foundation
import Testing

@testable import Daemon

/// A project's switches are Kelp's own, and a chat that starts hears them on its command line: Claude Code in the one
/// settings file beside Kelp's hooks, Kelp's own skill by its folder left out, a restart with today's.
@Test func whatsOffInAProjectStaysOutOfItsNewChats() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), setup = w.d.sessions.setup
    let skills = w.root.appendingPathComponent("agent-skills")
    for name in ["kelp-settings", "kelp-terminals"] {
        try FileManager.default.createDirectory(
            at: skills.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let claude = try setup.manifest("claude", command: nil)
    let plain = try setup.settingsFile(claude, worktreeId: wt.id)
    #expect(plain.lastPathComponent == "hooks-claude.json")

    for key in ["skill:tabbit", "plugin:sales", "server:claude_ai_Gmail", "kelp:kelp-terminals"] {
        _ = try await w.c.call(AddonsSet(worktreeId: wt.id, key: key, on: false))
    }
    let listed = try await w.c.call(AddonsList(worktreeId: wt.id))
    #expect(listed.items.first { $0.key == "plugin:sales" }?.kind == .plugin)
    #expect(listed.items.first { $0.key == "server:claude_ai_Gmail" }?.name == "Gmail")
    #expect(listed.items.filter(\.off).count == 4)

    let file = try setup.settingsFile(claude, worktreeId: wt.id)
    #expect(file != plain && file.lastPathComponent.hasPrefix("hooks-claude-"))
    let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    #expect(written["hooks"] != nil)
    #expect(written["skillOverrides"] == .object(["tabbit": "off"]))
    #expect(written["enabledPlugins"] == .object(["sales@synced": false]))
    #expect(written["permissions"] == .object(["deny": .array(["mcp__claude_ai_Gmail"])]))
    let args = setup.skillArgs(flag: "--plugin-dir", contextFlag: nil, worktreeId: wt.id, cwd: wt.path)
    #expect(args.argv == ["--plugin-dir", skills.path + "/kelp-settings"])

    // A restart carries the file it had: it gets today's. Someone's own --settings stays theirs.
    let old = ["claude", "--settings", plain.path, "--settings", "/mine.json"]
    #expect(
        try setup.withSettings(old, flag: "--settings", manifest: claude, worktreeId: wt.id, fresh: false)
            == ["claude", "--settings", file.path, "--settings", "/mine.json"])
    _ = try await w.c.call(AddonsSet(worktreeId: wt.id, key: "skill:tabbit", on: true))
    _ = try await w.c.call(AddonsSet(worktreeId: wt.id, key: "plugin:sales", on: true))
    _ = try await w.c.call(AddonsSet(worktreeId: wt.id, key: "server:claude_ai_Gmail", on: true))
    #expect(try setup.settingsFile(claude, worktreeId: wt.id) == plain)
}

@Test func switchesAsEachAgentHearsThem() {
    let off: Set = ["skill:anthropic-skills:docx", "plugin:ponytail", "server:node_repl", "kelp:kelp-vm"]
    let settings = AddonSwitches.claudeSettings(off, plugins: ["ponytail@ponytail", "sales@x"])
    #expect(settings["skillOverrides"] == .object(["anthropic-skills:docx": "off", "docx": "off"]))
    #expect(settings["enabledPlugins"] == .object(["ponytail@ponytail": false]))
    #expect(AddonSwitches.claudeSettings(["kelp:kelp-vm"], plugins: []).isEmpty)
    #expect(
        AddonSwitches.codexArgs(off, servers: ["node_repl", "other"]) == ["-c", "mcp_servers.node_repl.enabled=false"])
    let items = [
        Addon(kind: .skill, name: "tabbit", source: .yours, agents: ["claude", "codex", "cursor"], key: "skill:tabbit"),
        Addon(kind: .server, name: "node_repl", source: .yours, agents: ["codex"], key: "server:node_repl")
    ]
    let out = AddonSwitches.applied(off, to: items)
    #expect(out[0].fixed == ["codex", "cursor"] && !out[0].off)
    #expect(out[1].fixed.isEmpty && out[1].off)
    #expect(out.dropFirst(2).map(\.id) == ["skill:kelp-vm", "plugin:ponytail", "skill:anthropic-skills:docx"])
}

/// A server added through Kelp sits in Kelp's own file and goes to the agents that take one at a start: Claude Code by
/// the file, Codex on its command line, with what it signs in with in the chat's environment and not in the command.
@Test func aServerAddedOnceGoesToTheAgentsThatTakeOne() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), setup = w.d.sessions.setup
    let entry = ServerEntry(command: "npx", args: ["-y", "pkg"], env: ["API_KEY": "secret"])
    _ = try await w.c.call(AddonsAdd(worktreeId: wt.id, name: "context7", entry: entry))
    _ = try await w.c.call(
        AddonsAdd(
            worktreeId: wt.id, name: "linear", entry: ServerEntry(url: "https://l.app/mcp", headers: ["Auth": "t"])))
    #expect(ServerFiles.read(setup.serversFile)["context7"] == entry)
    let mode = try FileManager.default.attributesOfItem(atPath: setup.serversFile.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let listed = try await w.c.call(AddonsList(worktreeId: wt.id)).items.first { $0.key == "server:context7" }
    #expect(listed?.origin == Addon.kept && listed?.agents == ["claude", "codex"] && listed?.fixed == [])

    #expect(setup.withServers(["claude"], flag: "--mcp-config") == ["claude", "--mcp-config", setup.serversFile.path])
    let codex = setup.withCodexSwitches(["codex", "resume", "--last"], worktreeId: wt.id)
    #expect(
        codex == [
            "codex", "-c", #"mcp_servers.context7={command="npx",args=["-y","pkg"],env_vars=["API_KEY"]}"#,
            "-c", #"mcp_servers.linear={url="https://l.app/mcp",env_http_headers={"Auth"="KELP_MCP_LINEAR_AUTH"}}"#,
            "resume", "--last"
        ])
    #expect(!codex.joined().contains("secret"))
    #expect(setup.codexEnvironment(worktreeId: wt.id) == ["API_KEY": "secret", "KELP_MCP_LINEAR_AUTH": "t"])
    #expect(setup.withCodexSwitches(codex, worktreeId: wt.id) == codex)   // a restart's, chosen again

    // Off in the project: Codex isn't handed it; Claude Code's settings deny it (the file is one for every project).
    _ = try await w.c.call(AddonsSet(worktreeId: wt.id, key: "server:context7", on: false))
    #expect(setup.withCodexSwitches(["codex"], worktreeId: wt.id).count == 3)
    _ = try await w.c.call(AddonsRemove(worktreeId: wt.id, key: "server:context7"))
    _ = try await w.c.call(AddonsRemove(worktreeId: wt.id, key: "server:linear"))
    #expect(setup.withServers(["claude", "--mcp-config", setup.serversFile.path], flag: "--mcp-config") == ["claude"])
    #expect(setup.addonsOff(worktreeId: wt.id).off.isEmpty)
    await #expect(throws: (any Error).self) {
        _ = try await w.c.call(AddonsRemove(worktreeId: wt.id, key: "server:pencil"))
    }
}

/// A server's entry is read back for editing; only a skill of the person's own is moved or linked.
@Test func entriesAreReadBackAndOnlyOwnSkillsMove() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let entry = ServerEntry(command: "npx", args: ["-y", "pkg"])
    _ = try await w.c.call(AddonsAdd(worktreeId: wt.id, name: "context7", entry: entry, project: true))
    #expect(try await w.c.call(AddonsEntry(worktreeId: wt.id, key: "server:context7")) == entry)
    await #expect(throws: (any Error).self) {
        _ = try await w.c.call(AddonsEntry(worktreeId: wt.id, key: "server:none"))
    }
    for key in ["skill:sales:call-prep", "server:context7", "skill:no-such-skill"] {
        await #expect(throws: (any Error).self) { _ = try await w.c.call(AddonsTrash(worktreeId: wt.id, key: key)) }
        await #expect(throws: (any Error).self) { _ = try await w.c.call(AddonsLink(worktreeId: wt.id, key: key)) }
    }
    await #expect(throws: (any Error).self) {
        _ = try await w.c.call(AddonsInstall(worktreeId: wt.id, source: "not a place"))
    }
}

/// An agent with no flag for Kelp's skills (Codex, Antigravity, Grok) finds them in the folder it works in, out of git;
/// one turned off in the project goes from there too.
@Test func kelpsSkillsGoIntoTheProjectForAgentsWithoutAFlag() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), setup = w.d.sessions.setup
    let skills = w.root.appendingPathComponent("agent-skills")
    for name in ["kelp-settings", "kelp-terminals"] {
        let file = skills.appendingPathComponent("\(name)/skills/\(name)/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\n".write(to: file, atomically: true, encoding: .utf8)
    }
    _ = setup.writeProjectSkills(worktreeId: wt.id, cwd: wt.path)
    let folder = URL(fileURLWithPath: wt.path).appendingPathComponent(".agents/skills")
    let listed = { (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? [] }
    #expect(listed() == ["kelp-settings", "kelp-terminals"])
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("kelp-settings/SKILL.md").path))
    let exclude = try String(
        contentsOf: URL(fileURLWithPath: wt.path).appendingPathComponent(".git/info/exclude"), encoding: .utf8)
    #expect(exclude.contains("/.agents/skills/kelp-*/"))
    _ = try await w.c.call(AddonsSet(worktreeId: wt.id, key: "kelp:kelp-terminals", on: false))
    _ = setup.writeProjectSkills(worktreeId: wt.id, cwd: wt.path)
    #expect(listed() == ["kelp-settings"])
}
