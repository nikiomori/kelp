import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon

private func folder(_ files: [String: String]) throws -> URL {
    let d = tmp()
    for (name, text) in files {
        let u = d.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    return d
}

/// A web app is told by its files: a dev script beside a framework, a Python web framework, a page, a served port.
@Test func aWebAppIsFoundByItsFiles() throws {
    let vite = #"{"scripts": {"dev": "vite"}, "devDependencies": {"vite": "5"}}"#
    #expect(WebApp.found(in: try folder(["package.json": vite])) == "Vite in package.json")
    #expect(WebApp.found(in: try folder(["web/package.json": vite])) == "Vite in package.json (web)")
    #expect(
        WebApp.found(in: try folder(["requirements.txt": "numpy\nflask-cors\nFlask>=3\n"]))
            == "Flask in requirements.txt")
    #expect(
        WebApp.found(in: try folder(["pyproject.toml": "dependencies = [\n  \"fastapi>=0.1\",\n]\n"]))
            == "FastAPI in pyproject.toml")
    #expect(WebApp.found(in: try folder(["index.html": "<p>hi"])) == "index.html")
    #expect(
        WebApp.found(in: try folder(["compose.yaml": "services:\n  web:\n    ports:\n      - 80:80\n"]))
            == "ports in compose.yaml")
    // A library (no dev script), a CLI on Python, a Swift package: nothing to look at in a browser.
    #expect(
        WebApp.found(
            in: try folder(["package.json": #"{"scripts": {"test": "jest"}, "dependencies": {"react": "18"}}"#])) == nil
    )
    #expect(WebApp.found(in: try folder(["requirements.txt": "requests\nflasky\n"])) == nil)
    #expect(WebApp.found(in: try folder(["Package.swift": "// swift"])) == nil)
    #expect(WebApp.found(in: try folder(["node_modules/x/package.json": vite])) == nil)
}

/// In web projects (the default) a chat gets the browser where the files say so, a local page is open, or an agent used
/// it; Settings' Always / Never and a project's own choice come first.
@Test func theBrowserSkillFollowsSettingsTheProjectAndItsUse() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    func skill() async throws -> BrowserSkill { try await w.c.call(SkillsBrowser(worktreeId: wt.id)) }
    func state(_ k: String, _ v: JSONValue?) async throws { _ = try await w.c.call(StateSet(key: k, value: v)) }

    #expect(try await skill() == BrowserSkill(on: false, .noWebApp, hint: true))
    try #"{"scripts": {"dev": "vite"}, "devDependencies": {"vite": "5"}}"#.write(
        toFile: wt.path + "/package.json", atomically: true, encoding: .utf8)
    #expect(try await skill() == BrowserSkill(framework: "Vite in package.json"))
    try FileManager.default.removeItem(atPath: wt.path + "/package.json")

    let tabs: JSONValue = .object([
        "groups": .object(["g": .object(["tabs": .array([.object(["uri": "http://localhost:5173/"])])])])
    ])
    try await state("layout/\(wt.id)", tabs)
    #expect(try await skill().why == "a local page is open here")
    try await state(
        "layout/\(wt.id)",
        .object(["groups": .object(["g": .object(["tabs": .array([.object(["uri": "https://github.com/x"])])])])]))
    #expect(try await skill().on == false)

    _ = try? await w.c.call(UIBrowser(action: .info, worktreeId: wt.id))   // no app to do it, but the try counts
    #expect(try await skill() == BrowserSkill(on: true, .used))

    try await state(BrowserSkill.choiceKey(w.repo.id), "off")
    #expect(try await skill() == BrowserSkill(on: false, .project, choice: .off, hint: true))
    try await state(BrowserSkill.choiceKey(w.repo.id), nil)
    _ = try w.d.settings.set("agents.skills.browser", "off")
    #expect(try await skill() == BrowserSkill(on: false, .never))
    _ = try w.d.settings.set("agents.skills.browser", .bool(true))   // the switch it used to be
    #expect(try await skill() == BrowserSkill(on: true, .always))
}

/// Each skill is its own --plugin-dir; one that's off is left out, and the agent hears where its guide is. A restart's argv
/// (the record's) has its skills chosen again, the old folder flag and Kelp's sentence taken out.
@Test func skillsAreChosenPerChatAndAgainAtARestart() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), skills = w.root.appendingPathComponent("agent-skills")
    for name in ["kelp-browser", "kelp-settings", "kelp-terminals"] {
        try FileManager.default.createDirectory(
            at: skills.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let made = w.d.sessions.setup.skillArgs(
        flag: "--plugin-dir", contextFlag: "--append-system-prompt", worktreeId: wt.id, cwd: wt.path)
    #expect(made.browser == "off · no web app found")
    #expect(
        made.argv.prefix(4) == [
            "--plugin-dir", skills.path + "/kelp-settings", "--plugin-dir", skills.path + "/kelp-terminals"
        ])
    let context = try #require(made.argv.last)
    #expect(
        context.hasPrefix(SessionSetup.kelpIntro) && context.contains("kelp-settings skill")
            && context.contains(skills.path + "/kelp-browser/skills/kelp-browser/SKILL.md"))

    let old = [
        "claude", "--settings", "/h.json", "--plugin-dir", skills.path, "--append-system-prompt",
        SessionSetup.kelpIntro + " old", "--resume", "abc",
        "--plugin-dir", "/elsewhere"
    ]
    #expect(SessionSetup.hasSkills(old, root: w.root))
    #expect(
        SessionSetup.withoutSkills(old, root: w.root, flag: "--plugin-dir", contextFlag: "--append-system-prompt")
            == ["claude", "--settings", "/h.json", "--resume", "abc", "--plugin-dir", "/elsewhere"])

    _ = try w.d.settings.set("agents.skills.browser", "on")
    var o = Sessions.Launch()
    o.argv = ["/bin/sh", "-c", "sleep 30", "--plugin-dir", skills.path]
    let s = try w.d.sessions.spawn(
        cwd: wt.path, manifest: try w.d.sessions.setup.manifest("claude", command: nil), worktreeId: wt.id, o)
    #expect(s.browser == "on · Always, in Settings")
    #expect(
        s.argv.filter { $0.hasPrefix(skills.path) }
            == ["kelp-browser", "kelp-settings", "kelp-terminals"].map { skills.path + "/" + $0 })
    #expect(!s.argv.contains(skills.path) && !s.argv.contains { $0.contains("SKILL.md") })
}

/// The machines skill goes to agents once there's a machine (a folder in vms/), and a hidden folder there isn't one.
@Test func theMachinesSkillComesWithAMachine() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w), fm = FileManager.default
    try fm.createDirectory(at: w.root.appendingPathComponent("agent-skills/kelp-vm"), withIntermediateDirectories: true)
    func vm() -> Bool {
        w.d.sessions.setup.skillArgs(flag: "--plugin-dir", contextFlag: nil, worktreeId: wt.id, cwd: wt.path).argv
            .contains {
                $0.hasSuffix("/kelp-vm")
            }
    }
    #expect(!vm())
    try fm.createDirectory(at: w.root.appendingPathComponent("vms/.unpack-1/deep"), withIntermediateDirectories: true)
    #expect(!vm())
    try fm.createDirectory(at: w.root.appendingPathComponent("vms/dev"), withIntermediateDirectories: true)
    #expect(vm())
}

/// Codex names the caller's thread and tool call, so its answer is exact: a call or thread at odds with the hooks is
/// refused.
@Test func browserRoutingUsesCodexCallAndThreadMetadata() throws {
    let main = AgentCommand(id: "call_root", command: "kelp browser snapshot")
    let mobile = AgentCommand(id: "call_mobile", command: main.command)
    let desktop = AgentCommand(id: "call_desktop", command: main.command)
    let agents = [mobile.id: "mobile", desktop.id: "desktop"]
    func driver(_ call: String?, _ thread: LiveSession.BrowserThread, _ running: [AgentCommand]) throws -> String? {
        try LiveSession.browsing(
            (call, thread), words: "snapshot", commands: running, agents: agents, hasSubagents: true)
    }
    #expect(try driver(mobile.id, .unknown, [main, desktop, mobile]) == "mobile")
    #expect(try driver(desktop.id, .child("desktop"), [main, mobile, desktop]) == "desktop")
    #expect(try driver(main.id, .unknown, [main, mobile]) == nil)
    #expect(try driver("call_without_hook", .root, [mobile]) == nil)
    #expect(try driver("call_without_hook", .child("no_hook"), [mobile]) == "no_hook")
    #expect(throws: RPCError.self) { try driver(mobile.id, .root, [mobile]) }
    #expect(throws: RPCError.self) { try driver(mobile.id, .child("desktop"), [mobile]) }
    #expect(throws: RPCError.self) { try driver("call_without_hook", .unknown, [mobile]) }
    var ended = mobile
    ended.outcome = .ok
    #expect(throws: RPCError.self) { try driver(mobile.id, .unknown, [ended]) }
}

/// With no call id (Claude Code), a `kelp browser` command is the one running with its words, by its hook's agent;
/// the same words run by two owners at once are refused.
@Test(arguments: [
    ("click e12", ["t1", "t2", "t3"], "mobile"),
    ("type e4", ["t1", "t2", "t3"], "desktop"),
    ("info", ["t1", "t3"], "desktop"),   // only one runs `kelp browser`
    ("info", ["t4"], nil),   // the main thread's
    ("snapshot", ["t5", "t1"], nil),   // the main thread browses while a subagent runs tests
    ("open http://localhost:3000", ["t6", "t7"], nil),   // its address as typed, beside a subagent's ask
    ("click e12", ["t6", "t8"], "desktop"),   // quoted
    ("info", ["t6", "t7"], nil)   // two run it, neither with these words: the main thread's
])
func aBrowserCommandIsTheOneRunningWithItsWords(words: String, running: [String], owner: String?) throws {
    let commands = [
        AgentCommand(id: "t1", command: "npm test"), AgentCommand(id: "t2", command: "kelp browser click e12"),
        AgentCommand(id: "t3", command: "cd web && kelp browser type e4 'hi'"),
        AgentCommand(id: "t4", command: "kelp browser info"), AgentCommand(id: "t5", command: "kelp browser snapshot"),
        AgentCommand(id: "t6", command: "kelp browser open localhost:3000"),
        AgentCommand(id: "t7", command: "kelp browser ask 'Log in please'"),
        AgentCommand(id: "t8", command: #"kelp browser click "e12""#)
    ]
    let agents = ["t1": "tests", "t2": "mobile", "t3": "desktop", "t7": "mobile", "t8": "desktop"]
    let mine = commands.filter { running.contains($0.id) }
    #expect(try LiveSession.browsing(words, mine, agents) == owner)
}

/// Two owners running the very same words can't be told apart: refused, not guessed. An ended command isn't the caller.
@Test func theSameBrowserWordsFromTwoOwnersAreRefused() throws {
    let main = AgentCommand(id: "t1", command: "kelp browser snapshot")
    var mobile = AgentCommand(id: "t2", command: "kelp browser snapshot")
    #expect(throws: RPCError.self) { try LiveSession.browsing("snapshot", [main, mobile], ["t2": "mobile"]) }
    mobile.outcome = .ok
    #expect(try LiveSession.browsing("snapshot", [main, mobile], ["t2": "mobile"]) == nil)
    #expect(UIBrowser.words(.click, .object(["ref": "e12", "session": "s"])) == "click e12")
}

@Test func browserRoutingRefusesAgentOwnerURIsInUIOpen() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    let agent = Session(worktreeId: wt.id, cwd: wt.path, command: "codex", agent: "codex")
    try w.d.store.save(agent)
    for uri in ["AGENTWEB:?session=other&url=https://example.test", "settings:browser"] {
        let tab = UIOpen(uri: uri, worktreeId: wt.id)
        #expect(throws: RPCError.self) { try w.d.allow(tab, conn: -1, caller: .session(agent.id)) }
        try w.d.allow(tab, conn: -1, caller: .user)
    }
}

@Test func browserRoutingReadsTheKelpPeersInitialEnvironment() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: try builtProduct("kelp"))
    peer.arguments = ["browser"]
    peer.standardInput = Pipe()   // browser waits for commands from stdin
    peer.environment = [
        "KELP_SOCKET": w.root.appendingPathComponent("kelp.sock").path,
        "CODEX_TOOL_CALL_ID": "call_test", "CODEX_THREAD_ID": "thread", "UNRELATED": "omitted"
    ]
    try peer.run()
    defer { if peer.isRunning { peer.terminate() } }
    #expect(Subprocess.arguments(peer.processIdentifier)?.last == "browser")
    #expect(
        Subprocess.environment(peer.processIdentifier, keys: ["CODEX_TOOL_CALL_ID", "CODEX_THREAD_ID", "MISSING"])
            == ["CODEX_TOOL_CALL_ID": "call_test", "CODEX_THREAD_ID": "thread"])
}

/// `kelp browser ask` asks on a session's row: from outside any session, it says where it runs instead of asking nobody.
@Test func aBrowserAskOutsideASessionSaysWhereItRuns() async throws {
    let w = try await world()
    defer { w.d.stop() }
    let wt = try await firstWorkspace(w)
    await #expect {
        _ = try await w.c.call(UIBrowserAsk(question: "Sign in", worktreeId: wt.id))
    } throws: { ($0 as? RPCError)?.message.contains("runs in a session of Kelp's") == true }
}
