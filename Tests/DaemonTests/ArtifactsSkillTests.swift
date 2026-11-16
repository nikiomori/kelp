import AgentData
import Core
import Foundation
import Testing

@testable import Daemon

/// Kelp's pages go, by default, to agents without artifacts of their own: a Claude Code whose last chat loaded
/// claude-artifacts goes without; Codex and the rest, and a Claude Code that loaded none, get them. All Agents and Off
/// are for everyone.
@Test func theArtifactsSkillSkipsAClaudeCodeWithItsOwn() throws {
    let d = try Daemon(root: tmp()), home = tmp(), setup = d.sessions.setup
    defer { d.stop() }
    d.agentUsage.conversations.homes.withLock {
        $0 = (home.appendingPathComponent("projects"), home.appendingPathComponent("sessions"))
    }
    try FileManager.default.createDirectory(
        at: setup.root.appendingPathComponent("agent-skills/kelp-artifacts"), withIntermediateDirectories: true)
    func gets(claude: Bool) -> Bool {
        setup.chosenSkills(worktreeId: nil, cwd: "/work/app", claude: claude).on.contains {
            $0.lastPathComponent == "kelp-artifacts"
        }
    }
    func chat(_ id: String, loaded server: String?, at: Date) throws {
        let dir = ClaudeHistory.folder(cwd: "/work/app", root: home.appendingPathComponent("projects"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let note = server.map {
            #"{"type":"attachment","attachment":{"type":"deferred_tools_delta","addedNames":["mcp__\#($0)__copy_asset"]}}"#
        }
        try (note ?? #"{"type":"user","message":{"role":"user","content":"hi"}}"#).appending("\n")
            .write(to: dir.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        _ = try d.store.save(
            Session(
                cwd: "/work/app", command: "claude", agent: "claude", createdAt: at,
                argv: ["claude", "--session-id", id]))
    }

    #expect(gets(claude: true) && gets(claude: false))   // nothing to go by yet
    try chat("a", loaded: "claude-artifacts", at: Date(timeIntervalSinceNow: -60))
    #expect(!gets(claude: true) && gets(claude: false))
    try chat("b", loaded: nil, at: Date())   // just started: no note yet, the one before decides
    #expect(!gets(claude: true))
    try chat("c", loaded: "claude_ai_Gmail", at: Date(timeIntervalSinceNow: 60))
    #expect(gets(claude: true))   // signed in without claude.ai's artifacts

    _ = try d.settings.set(SettingKeys.skillArtifacts.key, "off")
    #expect(!gets(claude: true) && !gets(claude: false))
    try chat("d", loaded: "claude-artifacts", at: Date(timeIntervalSinceNow: 120))
    _ = try d.settings.set(SettingKeys.skillArtifacts.key, "all")
    #expect(gets(claude: true) && gets(claude: false))
}

/// The switch and the "where" choice older Kelps wrote become the one choice, once; the rest of the file stays.
@Test func oldArtifactsSettingsBecomeTheOneChoice() throws {
    let key = SettingKeys.skillArtifacts.key
    #expect(SettingsStore.upgraded(["editor.fontSize": 13, key: "all"]) == nil)
    #expect(SettingsStore.upgraded([key: .bool(false), "artifacts.where": "local"]) == [key: "off"])
    #expect(SettingsStore.upgraded(["artifacts.where": "local", "x": 1]) == [key: "all", "x": 1])
    #expect(SettingsStore.upgraded([key: .bool(true), "artifacts.where": "agent"]) == [:])

    let root = tmp()
    try #"{"agents.skills.artifacts": false, "artifacts.where": "local"}"#.write(
        to: root.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    #expect(SettingsStore(root: root).values == [key: "off"])
    #expect(SettingsStore(root: root).values == [key: "off"])   // written: read back as it is
}
