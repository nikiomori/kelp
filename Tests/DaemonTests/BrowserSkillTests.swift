import Core
import Foundation
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

/// A subagent's `kelp browser` says whose it is: of the commands running, the one with its words, by its hook's agent.
@Test func aBrowserCommandIsTheSubagentsThatRunsIt() {
    let main = AgentCommand(id: "t1", command: "npm test")
    let mobile = AgentCommand(id: "t2", command: "kelp browser click e12")
    let desktop = AgentCommand(id: "t3", command: "cd web && kelp browser type e4 'hi'")
    let agents = ["t2": "mobile", "t3": "desktop"]
    #expect(LiveSession.browsing("click e12", [main, mobile, desktop], agents) == "mobile")
    #expect(LiveSession.browsing("type e4", [main, mobile, desktop], agents) == "desktop")
    #expect(LiveSession.browsing("info", [main, desktop], agents) == "desktop")   // only one runs it
    var ended = mobile
    ended.outcome = .ok
    #expect(LiveSession.browsing("click e12", [ended], agents) == nil)   // over: not this call's
    #expect(LiveSession.browsing("info", [AgentCommand(id: "t4", command: "kelp browser info")], agents) == nil)   // the agent's own
    #expect(UIBrowser.words(.click, .object(["ref": "e12", "session": "s"])) == "click e12")
    // The agent's own command, its address as typed, while a subagent's waits: the agent's, not the subagent's.
    let asking = AgentCommand(id: "t5", command: "kelp browser ask 'Log in please'")
    let opening = AgentCommand(id: "t6", command: "kelp browser open localhost:3000")
    let quoted = AgentCommand(id: "t7", command: #"kelp browser click "e12""#)
    let all = agents.merging(["t5": "mobile", "t7": "desktop"]) { $1 }
    #expect(LiveSession.browsing("open http://localhost:3000", [asking, opening], all) == nil)
    #expect(LiveSession.browsing("click e12", [asking, quoted], all) == "desktop")
    #expect(LiveSession.browsing("info", [asking, opening], all) == nil)   // two run it, neither said so: the agent's
}
