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

@Test func aCodexServerIsReadForHandingOn() {
    let toml = """
        model = "x"
        [mcp_servers.node_repl]
        command = "/Applications/Chat GPT.app/node_repl"
        args = ["--stdio", "a b"]
        [mcp_servers.node_repl.env]
        NODE_PATH = "/x"
        [mcp_servers.remote]
        url = "https://r.dev/mcp"
        """
    #expect(
        AddonFiles.codexEntry("node_repl", in: toml)
            == ServerEntry(
                command: "/Applications/Chat GPT.app/node_repl", args: ["--stdio", "a b"], env: ["NODE_PATH": "/x"]))
    #expect(AddonFiles.codexEntry("remote", in: toml) == ServerEntry(url: "https://r.dev/mcp"))
    #expect(AddonFiles.codexEntry("none", in: toml) == nil)
}

/// The record is from the chat's start: a skill deleted since and a server taken out of the settings are gone, not
/// Claude Code's own. Its own are told by what /context says is built in, or by where they stand in the listing.
@Test func whatWasDeletedSinceTheChatStartedIsGone() throws {
    let lines = [
        #"{"type":"attachment","attachment":{"type":"skill_listing","isInitial":true,"content":"- web-perf: A\n- deleted: B\n- tabbit: C\n- init: D\n- sales:x: E"}}"#,
        #"{"type":"attachment","attachment":{"type":"deferred_tools_delta","addedNames":["mcp__claude-in-chrome__find","mcp__linear__list"],"failedMcpServers":[{"name":"old","error":"ENOENT"}]}}"#
    ]
    let loaded = ClaudeLoaded.read(Data(lines.joined(separator: "\n").utf8))
    let (files, cwd) = try home()
    let byOrder = AddonList.list(loaded: loaded, files: files, cwd: cwd, kelp: [])
    #expect(byOrder.gone == ["deleted", "linear", "old"])
    #expect(byOrder.items.contains { $0.id == "skill:init" && $0.source == .agent })
    #expect(byOrder.items.contains { $0.id == "server:claude-in-chrome" })
    #expect(!byOrder.items.contains { $0.name == "deleted" || $0.name == "old" || $0.name == "linear" })
    let known = AddonList.list(loaded: loaded, files: files, cwd: cwd, kelp: [], builtIn: ["deleted"])
    #expect(known.gone == ["init", "linear", "old"])
    let printed =
        "### Skills\n\n| Skill | Source | Tokens |\n|---|---|---|\n| init | Built-in | ~10 |\n| x | User | ~5 |\n"
    #expect(ClaudeBuiltIns.read(printed) == ["init"] && ClaudeBuiltIns.read("### MCP Tools\n") == nil)
}

/// A row says which file to open, and an error is short on the row and whole beside it.
@Test func rowsNameTheirFilesAndShortenErrors() throws {
    let (files, cwd) = try home()
    let items = AddonList.build(loaded: nil, files: files, cwd: cwd, kelp: [])
    #expect(items.first { $0.id == "skill:web-perf" }?.path?.hasSuffix(".agents/skills/web-perf/SKILL.md") == true)
    #expect(items.first { $0.id == "server:pencil" }?.path?.hasSuffix(".claude.json") == true)
    #expect(items.first { $0.id == "instructions:AGENTS.md" }?.path == cwd + "/AGENTS.md")
    #expect(
        AddonList.problem("Dynamic Client Registration rejected (HTTP 403): !DOCTYPE HTML PUBLIC")
            == "Sign-in refused (HTTP 403)")
    #expect(
        AddonList.problem("MCP endpoint not found at https://api.definite.app. Check the URL in your MCP config.")
            == "MCP endpoint not found at api.definite.app")
    #expect(AddonList.problem("") == "Doesn’t start")
}

/// A new skill sits once, in the shared folder, with a link in Claude Code's; a folder's skills are copied in the
/// same way; one only Claude Code has is linked for the others.
@Test func skillsAreMadeCopiedInAndLinked() throws {
    let (files, cwd) = try home()
    let made = try files.newSkill("notes", cwd: cwd, project: false)
    #expect(made.hasSuffix(".agents/skills/notes/SKILL.md"))
    let link = files.claude.appendingPathComponent("skills/notes")
    #expect(
        link.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: made).deletingLastPathComponent().resolvingSymlinksInPath().path)
    #expect(throws: (any Error).self) { _ = try files.newSkill("notes", cwd: cwd, project: false) }
    #expect(throws: (any Error).self) { _ = try files.newSkill("bad name", cwd: cwd, project: false) }

    let repo = tmp().appendingPathComponent("pack")
    try put("---\nname: a\n---\n", repo.appendingPathComponent("skills/alpha/SKILL.md"))
    try put("---\nname: b\n---\n", repo.appendingPathComponent("skills/beta/SKILL.md"))
    try put("x", repo.appendingPathComponent("skills/alpha/.git/HEAD"))
    let installed = try files.installSkills(from: repo, cwd: cwd, project: true)
    #expect(
        installed.map { ($0 as NSString).deletingLastPathComponent }.map { ($0 as NSString).lastPathComponent } == [
            "alpha", "beta"
        ])
    #expect(FileManager.default.fileExists(atPath: cwd + "/.claude/skills/alpha/SKILL.md"))
    #expect(!FileManager.default.fileExists(atPath: cwd + "/.agents/skills/alpha/.git"))
    #expect(throws: (any Error).self) { _ = try files.installSkills(from: tmp(), cwd: cwd, project: true) }

    // tabbit's second copy is Claude Code's own real folder; "solo" is only there: a link gives it to the others.
    try put("---\nname: solo\n---\n", files.claude.appendingPathComponent("skills/solo/SKILL.md"))
    try files.linkSkill("solo", cwd: cwd)
    let shared = files.home.appendingPathComponent(".agents/skills/solo")
    #expect(shared.resolvingSymlinksInPath().lastPathComponent == "solo")
    #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("SKILL.md").path))
    #expect(throws: (any Error).self) { try files.linkSkill("none", cwd: cwd) }
}
