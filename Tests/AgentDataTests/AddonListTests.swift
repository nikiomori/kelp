import Core
import Foundation
import TestSupport
import Testing

@testable import AgentData

private func put(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A home with a shared skill linked into Claude Code's folder, a second real copy of another, one server in each
/// agent's own file, and a project with both instruction files.
private func home() throws -> (files: AddonFiles, cwd: String) {
    let root = tmp(), project = root.appendingPathComponent("work")
    let shared = root.appendingPathComponent(".agents/skills"), own = root.appendingPathComponent(".claude/skills")
    for name in ["web-perf", "tabbit"] {
        try put(
            "---\nname: \(name)\ndescription: \"About \(name)\"\n---\nBody",
            shared.appendingPathComponent("\(name)/SKILL.md"))
    }
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: own.appendingPathComponent("web-perf"), withDestinationURL: shared.appendingPathComponent("web-perf"))
    try put("---\nname: tabbit\n---\n", own.appendingPathComponent("tabbit/SKILL.md"))
    try put(#"{"mcpServers":{"pencil":{"command":"x"}}}"#, root.appendingPathComponent(".claude.json"))
    try put(
        "[mcp_servers.node_repl]\ncommand = \"n\"\n[mcp_servers.node_repl.env]\nA = \"b\"\n[mcp_servers.off]\nenabled = false\n",
        root.appendingPathComponent(".codex/config.toml"))
    try put("claude", project.appendingPathComponent("CLAUDE.md"))
    try put("agents", project.appendingPathComponent("AGENTS.md"))
    let files = AddonFiles(
        home: root, claude: root.appendingPathComponent(".claude"), codex: root.appendingPathComponent(".codex"))
    return (files, project.path)
}

@Test func aChatsRecordSaysWhatItLoaded() throws {
    let lines = [
        #"{"type":"attachment","attachment":{"type":"skill_listing","isInitial":true,"content":"- web-perf: Audit pages\n- sales:call-prep: Prepare: a call\n- kelp-vm:kelp-vm: Machines\n- anthropic-skills:pdf: PDFs\n- init"}}"#,
        #"{"type":"attachment","attachment":{"type":"deferred_tools_delta","addedNames":["CronList","mcp__claude_ai_Gmail__get_thread","mcp__plugin_figma_figma__authenticate","mcp__plugin_figma_figma__complete_authentication"],"failedMcpServers":[{"name":"pencil","errorCode":"ENOENT","error":"ENOENT: no such file"}]}}"#,
        #"{"type":"attachment","attachment":{"type":"instructions","files":[{"path":"/w/CLAUDE.md","type":"Project","content":"abcdefgh"}]}}"#,
        #"{"type":"user","message":{"content":"attachment"}}"#
    ]
    let loaded = ClaudeLoaded.read(Data(lines.joined(separator: "\n").utf8))
    #expect(
        loaded.skills.map(\.name) == ["web-perf", "sales:call-prep", "kelp-vm:kelp-vm", "anthropic-skills:pdf", "init"])
    #expect(loaded.skills[1].about == "Prepare: a call")
    #expect(
        loaded.tools == [
            "claude_ai_Gmail": ["get_thread"], "plugin_figma_figma": ["authenticate", "complete_authentication"]
        ])
    #expect(loaded.failed == ["pencil": "ENOENT: no such file"])
    #expect(loaded.files == [.init(path: "/w/CLAUDE.md", type: "Project", chars: 8)])

    let (files, cwd) = try home()
    let items = AddonList.build(loaded: loaded, files: files, cwd: cwd, kelp: [])
    func item(_ id: String) throws -> Addon { try #require(items.first { $0.id == id }) }
    let perf = try item("skill:web-perf")
    #expect(perf.source == .yours && perf.origin == "~/.agents/skills" && perf.loaded == true)
    #expect(perf.agents.contains("codex") && perf.agents.contains("claude") && perf.copies.isEmpty)
    #expect(try item("skill:sales:call-prep").source == .plugin)
    #expect(try item("skill:kelp-vm").source == .kelp)
    #expect(try item("skill:pdf").origin == "claude.ai")
    #expect(try item("skill:init").source == .agent)
    #expect(try item("server:Gmail").source == .account)
    let figma = try item("server:figma")
    #expect(figma.signIn && figma.origin == "figma" && figma.source == .plugin)
    let pencil = try item("server:pencil")
    #expect(
        pencil.source == .yours && pencil.problem == "Doesn’t start: its program isn’t there" && pencil.loaded == false)
    // What Claude Code never loads still shows, as other agents': Codex's server, the copy of a skill it didn't list.
    #expect(try item("server:node_repl").agents == ["codex"])
    #expect(items.contains { $0.id == "server:off" } == false)
    #expect(try item("skill:tabbit").copies == ["~/.claude/skills/tabbit"])
    #expect(try item("instructions:AGENTS.md").agents.contains("claude") == false)
}

@Test func withoutAChatTheFilesSay() throws {
    let (files, cwd) = try home()
    let items = AddonList.build(loaded: nil, files: files, cwd: cwd, kelp: ["kelp-vm"])
    #expect(items.allSatisfy { $0.loaded == nil })
    #expect(
        items.map(\.id).sorted() == [
            "instructions:AGENTS.md", "instructions:CLAUDE.md", "server:node_repl", "server:pencil", "skill:kelp-vm",
            "skill:tabbit", "skill:web-perf"
        ])
}
