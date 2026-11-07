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

    #expect(try await skill() == BrowserSkill(on: false, why: "no web app found", hint: true))
    try #"{"scripts": {"dev": "vite"}, "devDependencies": {"vite": "5"}}"#.write(
        toFile: wt.path + "/package.json", atomically: true, encoding: .utf8)
    #expect(try await skill() == BrowserSkill(on: true, why: "Vite in package.json"))
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

    _ = try? await w.c.call(UIBrowser(action: "info", worktreeId: wt.id))   // no app to do it, but the try counts
    #expect(try await skill() == BrowserSkill(on: true, why: "an agent used it here"))

    try await state(BrowserSkill.choiceKey(w.repo.id), "off")
    #expect(try await skill() == BrowserSkill(on: false, why: "set for this project", choice: "off", hint: true))
    try await state(BrowserSkill.choiceKey(w.repo.id), nil)
    _ = try w.d.settings.set("agents.skills.browser", "off")
    #expect(try await skill() == BrowserSkill(on: false, why: "Never, in Settings"))
    _ = try w.d.settings.set("agents.skills.browser", .bool(true))   // the switch it used to be
    #expect(try await skill() == BrowserSkill(on: true, why: "Always, in Settings"))
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
    let made = w.d.sessions.skillArgs(
        flag: "--plugin-dir", contextFlag: "--append-system-prompt", worktreeId: wt.id, cwd: wt.path)
    #expect(made.browser == "off · no web app found")
    #expect(
        made.argv.prefix(4) == [
            "--plugin-dir", skills.path + "/kelp-settings", "--plugin-dir", skills.path + "/kelp-terminals"
        ])
    let context = try #require(made.argv.last)
    #expect(
        context.hasPrefix(Sessions.kelpIntro) && context.contains("kelp-settings skill")
            && context.contains(skills.path + "/kelp-browser/skills/kelp-browser/SKILL.md"))

    let old = [
        "claude", "--settings", "/h.json", "--plugin-dir", skills.path, "--append-system-prompt",
        Sessions.kelpIntro + " old", "--resume", "abc",
        "--plugin-dir", "/elsewhere"
    ]
    #expect(Sessions.hasSkills(old, root: w.root))
    #expect(
        Sessions.withoutSkills(old, root: w.root, flag: "--plugin-dir", contextFlag: "--append-system-prompt")
            == ["claude", "--settings", "/h.json", "--resume", "abc", "--plugin-dir", "/elsewhere"])

    _ = try w.d.settings.set("agents.skills.browser", "on")
    var o = Sessions.Launch()
    o.argv = ["/bin/sh", "-c", "sleep 30", "--plugin-dir", skills.path]
    let s = try w.d.sessions.spawn(
        cwd: wt.path, manifest: try w.d.sessions.manifest("claude", command: nil), worktreeId: wt.id, o)
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
        w.d.sessions.skillArgs(flag: "--plugin-dir", contextFlag: nil, worktreeId: wt.id, cwd: wt.path).argv.contains {
            $0.hasSuffix("/kelp-vm")
        }
    }
    #expect(!vm())
    try fm.createDirectory(at: w.root.appendingPathComponent("vms/.unpack-1/deep"), withIntermediateDirectories: true)
    #expect(!vm())
    try fm.createDirectory(at: w.root.appendingPathComponent("vms/dev"), withIntermediateDirectories: true)
    #expect(vm())
}
