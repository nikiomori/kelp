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
