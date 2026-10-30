import Foundation
import Testing
import Core
@testable import Agents
import TestSupport

@Test func heuristicWaitingVsDone() throws {
    let t0 = Date()
    let codex = try #require(AgentManifest.presets.first { $0.id == "codex" })   // no hooks: status comes from output
    var d = StatusDetector(manifest: codex)
    d.input()   // the user gave it a task
    d.output("\u{1B}[1mDo you want to proceed? [y/n]\u{1B}[0m", at: t0)
    #expect(d.status == .working)
    #expect(d.tick(at: t0.addingTimeInterval(1)) == .working)
    #expect(d.tick(at: t0.addingTimeInterval(4)) == .waiting)

    var e = StatusDetector(manifest: codex)
    e.input()
    e.output("all done, 3 files changed", at: t0)
    #expect(e.tick(at: t0.addingTimeInterval(4)) == .done)
}

@Test func hooksOverrideHeuristics() {
    let t0 = Date()
    var d = StatusDetector(manifest: .presets[0])
    d.hook("working")
    d.output("whatever", at: t0)
    #expect(d.tick(at: t0.addingTimeInterval(60)) == .working)
    d.hook("done")
    #expect(d.status == .done)
}

@Test func manifestFilesOverridePresets() throws {
    let dir = tmp()
    try JSONEncoder().encode(AgentManifest(id: "mine", name: "Mine", command: "mine-cli")).write(to: dir.appendingPathComponent("mine.json"))
    try Data("{bad".utf8).write(to: dir.appendingPathComponent("bad.json"))
    let all = AgentManifest.load(dir: dir)
    #expect(all.contains { $0.id == "mine" } && all.contains { $0.id == "claude" })
}

@Test func hermesPresetUsesSupportedInstallAndModelFlow() throws {
    let hermes = try #require(AgentManifest.presets.first { $0.id == "hermes" })
    #expect(hermes.command == "hermes")
    #expect(hermes.modelFlag == nil)
    #expect(hermes.autoAnswers.isEmpty)
    let installed = AgentManifest.withInstall(hermes)
    #expect(installed.install == "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash")
    #expect(installed.update == "hermes update")
}

@Test func kimiCodeUsesDocumentedModelAndContinueFlags() throws {
    let kimi = try #require(AgentManifest.presets.first { $0.id == "kimi" })
    #expect(kimi.argv(model: "kimi-k2.5") == ["kimi", "--model", "kimi-k2.5"])
    #expect(kimi.argv(resume: true) == ["kimi", "--continue"])
    #expect(kimi.autoAnswers.contains(AgentManifest.trust))
    #expect(kimi.sessionIdFlag == nil && kimi.resumeIdFlag == nil)  // --session resumes only; no create-under-id
    #expect(AgentManifest.withInstall(kimi).install?.contains("code.kimi.com") == true)
}

@Test func installedAgentsKeepTheirModelAndContinueFlags() throws {
    for id in ["pi", "grok", "antigravity", "qwen", "kilo", "crush", "droid", "copilot"] {
        let m = try #require(AgentManifest.presets.first { $0.id == id })
        #expect(m.argv(resume: true) != m.argv(), "\(id) resumes")
    }
    // Droid merges a `--settings` file for the run, and runs Claude-style hooks from it (checked with droid exec 0.248).
    #expect(AgentManifest.presets.first { $0.id == "droid" }?.hooks == .settingsFlag("--settings"))
    let agy = try #require(AgentManifest.presets.first { $0.id == "antigravity" })
    #expect(agy.argv(model: "m", effort: "high", resume: true) == ["agy", "--model", "m", "--effort", "high", "--continue"])
}

@Test func hooksSettingsIsValidJSON() throws {
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(Hooks.settingsJSON().utf8))
    #expect(v["hooks"]?["Stop"] != nil)
    #expect(v["hooks"]?["PreToolUse"]?.array?.first?["matcher"]?.string == "AskUserQuestion")
    for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {   // each Bash command, as it starts and ends
        let bash = v["hooks"]?[event]?.array?.first { $0["matcher"]?.string == "Bash" }
        #expect(bash?["hooks"]?.array?.first?["command"]?.string == "kelp hook command")
    }
    #expect(v["hooks"]?["PermissionRequest"]?.array?.first?["hooks"]?.array?.first?["command"]?.string == "kelp hook waiting")
}

/// Qwen Code's system settings (an admin's policy) stay in force with Kelp's file in their place, their hooks too.
@Test func hooksSettingsKeepTheFileTheyStandFor() throws {
    let dir = tmp(), base = dir.appendingPathComponent("system.json"), out = dir.appendingPathComponent("hooks.json")
    try Data(#"{"tools":{"sandbox":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"audit"}]}]}}"#.utf8).write(to: base)
    try Hooks.writeSettings(to: out, over: base)
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: out))
    #expect(v["tools"]?["sandbox"]?.bool == true)
    #expect(v["hooks"]?["Stop"]?.array?.count == 2 && v["hooks"]?["Notification"] != nil)
    try Hooks.writeSettings(to: out, over: dir.appendingPathComponent("none.json"))   // no such file: Kelp's hooks alone
    #expect(try String(contentsOf: out, encoding: .utf8) == Hooks.settingsJSON())
    // There but not plain JSON (comments): not stood in for, so the caller wires no hooks.
    try Data("// policy\n{\"tools\":{}}".utf8).write(to: base)
    #expect(throws: (any Error).self) { try Hooks.writeSettings(to: out, over: base) }
}

@Test func notificationsThatAskNothingAreNotQuestions() {
    func note(_ type: String, _ message: String = "") -> JSONValue { .obj(["notification_type": .string(type), "message": .string(message)]) }
    #expect(Hooks.isInformational(note("idle_prompt", "Claude is waiting for your input")))
    #expect(Hooks.isInformational(note("auth_success", "Login successful")))
    #expect(Hooks.isInformational(note("agent_completed", "Review finished")))
    #expect(Hooks.isInformational(note("push_notification")) && Hooks.isInformational(note("computer_use_exit")))
    #expect(!Hooks.isInformational(note("permission_prompt", "Claude needs your permission to use Bash")))
    #expect(!Hooks.isInformational(note("elicitation_dialog")) && !Hooks.isInformational(note("agent_needs_input")))
    #expect(!Hooks.isInformational(note("a_type_it_has_not_had_before")))   // asked until known to ask nothing
    #expect(Hooks.isInformational(.obj(["message": "Claude is waiting for your input"])))   // Qwen Code names no type
}

/// A permission dialog says what it would do; the vague notice Claude Code sends six seconds later doesn't replace that.
@Test func aPermissionRequestSaysWhatItWouldRun() {
    func ask(_ tool: String, _ input: JSONValue) -> JSONValue {
        .obj(["notification_type": "permission_request", "tool_name": .string(tool), "tool_input": input, "cwd": "/repo"])
    }
    #expect(Hooks.permissionAsk(ask("Bash", .obj(["command": "rm -rf node_modules\necho done"]))) == "Allow rm -rf node_modules?")
    #expect(Hooks.permissionAsk(ask("Edit", .obj(["file_path": "/repo/Sources/App.swift"]))) == "Allow editing Sources/App.swift?")
    #expect(Hooks.permissionAsk(ask("Write", .obj(["file_path": "/etc/hosts"]))) == "Allow writing /etc/hosts?")
    #expect(Hooks.permissionAsk(ask("WebFetch", .obj(["url": "https://example.com/a?b"]))) == "Allow fetching example.com?")
    #expect(Hooks.permissionAsk(ask("mcp__github__create_issue", .obj([:]))) == "Allow github: create_issue?")
    #expect(Hooks.permissionAsk(ask("Bash", .obj(["command": .string(String(repeating: "x", count: 200))]))).count == 127)
    let question: JSONValue = .obj(["questions": .array([.obj(["header": "Merge mode", "question": "What should merge do?"])])])
    #expect(Hooks.permissionAsk(ask("AskUserQuestion", question)) == "What should merge do?")
    #expect(Hooks.permissionAsk(ask("AskUserQuestion", .obj([:]))) == "Allow AskUserQuestion?")
    let vague: JSONValue = .obj(["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
    #expect(Hooks.message(vague, alreadyWaiting: true) == nil)
    #expect(Hooks.message(vague, alreadyWaiting: false) == "Claude needs your permission to use Bash")
    #expect(Hooks.message(ask("Bash", .obj(["command": "make"])), alreadyWaiting: false) == "Allow make?")
}

@Test func stripKeepsWordGapsFromCursorMoves() {
    let raw = "\u{1B}[2GQuick\u{1B}[8Gsafety\u{1B}[15Gcheck: one\u{1B}[30Gyou trust?\n\u{1B}[2G\u{1B}[38;2;177;185;249m❯\u{1B}[4GNo,\u{1B}[8Gexit\u{1B}[39m\n\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust\n"
    let t = StatusDetector.stripANSI(raw)
    #expect(t.contains("one you trust"))
    #expect(AgentManifest.AutoAnswer.optionAtCursor(t) == "No, exit")
}

@Test func stripRemovesCharsetSelection() {
    #expect(StatusDetector.stripANSI("\u{1B}(Bhi") == "hi")
    #expect(StatusDetector.stripANSI("Trust\u{1B}[5;9Hthis\u{1B}[5;14Hfolder?") == "Trust this folder?")
    #expect(StatusDetector.stripANSI("\u{1B}(B") == "")
    #expect(StatusDetector.stripANSI("\u{1B}(B\u{1B}(B") == "")
    #expect(StatusDetector.stripANSI("\u{1B})0hello\u{1B}*B\u{1B}+A") == "hello")
}

@Test func cursorOptionHandlesCRLF() {
    // Real Claude Code bytes: options separated by "\r\r\n" (one Character in Swift).
    let raw = "\u{1B}[2G\u{1B}[38;2;177;185;249m❯\u{1B}[4GNo,\u{1B}[8Gexit\u{1B}[39m\r\r\n\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust\r\r\n"
    #expect(AgentManifest.AutoAnswer.optionAtCursor(StatusDetector.stripANSI(raw)) == "No, exit")
    // After moving down, Ink redraws just the two lines: the last ❯ is on Yes.
    let moved = raw + "\u{1B}[2A\u{1B}[4GNo,\u{1B}[8Gexit\r\r\n\u{1B}[2G❯\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust"
    #expect(AgentManifest.AutoAnswer.optionAtCursor(StatusDetector.stripANSI(moved)) == "Yes, I trust")
}

@Test func claudeLimitMessagesParse() {
    let a = ClaudeLimits.parse("⏵⏵ auto mode on · You've used 80% of your weekly limit · resets Oct 20 at 5am (Europe/Helsinki)")
    #expect(a == [.init(kind: "weekly", percent: 80, resets: "Oct 20 at 5am")])
    let b = ClaudeLimits.parse("You've used 93% of your session limit · resets 3pm")
    #expect(b.first?.kind == "session" && b.first?.percent == 93 && b.first?.resets == "3pm")
    #expect(ClaudeLimits.parse("5-hour limit reached ∙ resets 11pm").first?.percent == 100)
    #expect(ClaudeLimits.parse("You've used 82.5% of your weekly limit").first?.percent == 82.5)
    #expect(ClaudeLimits.parse("nothing to see").isEmpty)
}

@Test func claudeUsageParses() {
    let printed = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 2% used · resets 7:40am (Europe/Helsinki)
    Current week (all models): 82.5% used · resets Oct 20 at 5am (Europe/Helsinki)
    Current week (Fable): 0% used

    Last 24h · 3793 requests · 55 sessions
      81%  Start fresh when you switch tasks · run /clear
    """
    let r = ClaudeLimits.parseUsage(printed)
    #expect(r.map(\.kind) == ["session", "week", "week · Fable"])
    #expect(r[1].percent == 82.5 && r[1].resets == "Oct 20 at 5am")
    #expect(r[0].resets == "7:40am" && r[2].resets == nil)
}

@Test func resumeFindsThisConversationNotTheLatest() throws {
    let claude = try #require(AgentManifest.presets.first { $0.id == "claude" })
    let pinned = ["claude", "--settings", "h.json", "--session-id", "abc"]
    #expect(claude.resuming(pinned) == ["claude", "--settings", "h.json", "--resume", "abc"])
    #expect(claude.resuming(claude.resuming(pinned)) == claude.resuming(pinned))
    #expect(claude.resuming(["claude"]) == ["claude", "--continue"])   // sessions from before ids were pinned
    #expect(claude.resumes(["claude", "--resume", "x"]))
    // A fork (Kelp Dev's copy of a session) follows the conversation it made, and the next wake resumes that one.
    #expect(claude.following(["claude", "--resume", "abc", "--fork-session"], conversation: "def") == ["claude", "--session-id", "def"])
    #expect(claude.forking(pinned) == ["claude", "--settings", "h.json", "--resume", "abc", "--fork-session"])
    #expect(claude.forking(["claude"]) == nil)   // no id: `following` couldn't drop the flag, and each wake would fork again
    #expect(try #require(AgentManifest.presets.first { $0.id == "codex" }).forking(["codex", "--session-id", "abc"]) == nil)
}

@Test func hookedAgentsDontGuessFromOutput() throws {
    let claude = try #require(AgentManifest.presets.first { $0.id == "claude" })
    var d = StatusDetector(manifest: claude)
    d.output("✻ redraw", at: Date())
    #expect(d.status == .idle)
    d.hook("working"); #expect(d.status == .working)
}

/// Agent files keep the keys they always had: each one reads as its kind of hooks and is written back the same way.
@Test func agentFilesKeepTheirHookKeys() throws {
    let lines = [#""hooksSettingsFlag":"--settings""#, #""hooksConfigDirEnv":"KILO_CONFIG_DIR""#,
                 #""hooksSettingsEnv":"QWEN_CODE_SYSTEM_SETTINGS_PATH""#, #""hooksHerdr":true"#]
    let kinds: [HookTransport] = [.settingsFlag("--settings"), .pluginDir(env: "KILO_CONFIG_DIR"),
                                  .settingsFile(env: "QWEN_CODE_SYSTEM_SETTINGS_PATH", replaces: "/Library/Application Support/QwenCode/settings.json"), .herdr]
    for (line, kind) in zip(lines, kinds) {
        let m = try JSONDecoder().decode(AgentManifest.self, from: Data(#"{"id":"a","name":"A","command":"a",\#(line)}"#.utf8))
        #expect(m.hooks == kind)
        #expect(String(decoding: try JSONEncoder().encode(m), as: UTF8.self).contains(line))
        #expect(try JSONDecoder().decode(AgentManifest.self, from: try JSONEncoder().encode(m)) == m)
    }
    #expect(try JSONDecoder().decode(AgentManifest.self, from: Data(#"{"id":"a","name":"A","command":"a"}"#.utf8)).hooks == nil)
}

@Test func kiloAndQwenReportThroughTheirHooks() throws {
    let kilo = try #require(AgentManifest.presets.first { $0.id == "kilo" })
    #expect(kilo.hooks == .pluginDir(env: "KILO_CONFIG_DIR"))
    var d = StatusDetector(manifest: kilo)
    d.output("Thinking… esc interrupt", at: Date().addingTimeInterval(10))   // no turn guessed from what it prints
    #expect(d.status == .idle)
    d.hook("working"); #expect(d.status == .working)
    let qwen = try #require(AgentManifest.presets.first { $0.id == "qwen" })
    #expect(qwen.hooks?.env == "QWEN_CODE_SYSTEM_SETTINGS_PATH")
    #expect(Hooks.pluginJS.contains("parentID") && Hooks.pluginJS.contains("kelp\", [\"hook\""))
}

@Test func answeredQuestionIsNotAskedAgain() throws {
    let t0 = Date()
    let codex = try #require(AgentManifest.presets.first { $0.id == "codex" })
    var d = StatusDetector(manifest: codex)
    d.input()
    d.output("Do you want to proceed? (y/n)\n", at: t0)
    #expect(d.tick(at: t0.addingTimeInterval(4)) == .waiting)
    d.input()
    d.output("y\ndone, 2 files changed\n", at: t0.addingTimeInterval(5))
    #expect(d.tick(at: t0.addingTimeInterval(9)) == .done)
}

/// An agent's welcome menu isn't a question, and redraws without words aren't work.
@Test func welcomeScreenIsReady() throws {
    let t0 = Date()
    let grok = AgentManifest(id: "grok", name: "Grok", command: "grok")
    var d = StatusDetector(manifest: grok)
    d.output("New worktree\nResume session\n❯ 1. Quit\nDo you want to enable telemetry? (y/n)", at: t0)
    #expect(d.tick(at: t0.addingTimeInterval(10)) == .idle)
    d.input(); d.output("Thinking about your request", at: t0.addingTimeInterval(11))
    #expect(d.status == .working)
    d.output("\u{1B}[2K⠋ 12s", at: t0.addingTimeInterval(20))   // a spinner tick
    #expect(d.tick(at: t0.addingTimeInterval(20)) == .done)
    d.output("Worked for 9.0s", at: t0.addingTimeInterval(22))     // the footer after a finished turn
    #expect(d.status == .done)
    d.output("Reading more files", at: t0.addingTimeInterval(30))  // it really went on
    #expect(d.status == .working)
}

/// Replayed history keeps the screen but not the agent's questions to its terminal; the terminal's answers aren't typing.
@Test func terminalRepliesAreNotTyping() {
    let hist = Data("\u{1B}[>0q\u{1B}[c\u{1B}[?u\u{1B}]11;?\u{07}\u{1B}[1mGrok\u{1B}[0m \u{1B}[6n".utf8)
    #expect(String(bytes: TerminalReplies.withoutQueries(hist), encoding: .utf8) == "\u{1B}[1mGrok\u{1B}[0m ")
    let copied = Data("a\u{1B}]52;c;aGk=\u{07}b\u{1B}]52;c;aGk=\u{1B}\\c".utf8)   // Claude Code's copies over ssh
    #expect(String(bytes: TerminalReplies.withoutQueries(copied), encoding: .utf8) == "abc")
    #expect(TerminalReplies.isReply(Data("\u{1B}P>|ghostty 1.3.2\u{1B}\\\u{1B}[?62;22c\u{1B}[?1u\u{1B}[12;5R".utf8)))
    #expect(TerminalReplies.isReply(Data("\u{1B}]11;rgb:1e1e/1e1e/2222\u{07}".utf8)))
    #expect(!TerminalReplies.isReply(Data("\u{1B}[A".utf8)))     // arrow key
    #expect(!TerminalReplies.isReply(Data("\u{1B}[97;5u".utf8))) // kitty key press
    #expect(!TerminalReplies.isReply(Data("fix it\r".utf8)))
}

@Test func grokAndAntigravityUsageScreensParse() {
    let grok = "Context usage │ Usage limit │ Session info\n Weekly limit (X Premium)\n ██████░░░░ 45.5%\n Resets: October 24, 19:36\n Loading session usage…"
    #expect(ClaudeLimits.parseGrokUsage(grok) == [.init(kind: "week", percent: 45.5, resets: "October 24, 19:36")])
    let framed = "│ Weekly limit (X Premium)          │\n│ ██████░░░░ 45%                    │\n│ Resets: October 24, 19:36         │"
    #expect(ClaudeLimits.parseGrokUsage(framed).first?.percent == 45)
    let agy = "Gemini Models\tWeekly Limit Remaining\t88.25%\t2026-10-30T21:42:00Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\n"
    #expect(ClaudeLimits.parseAntigravityUsage(agy, timeZone: .gmt)
        == [.init(kind: "Gemini week", percent: 11.75, resets: "Oct 30 at 9:42pm"), .init(kind: "Claude week", percent: 0, resets: nil)])
}

@Test func kimiUsageScreenParses() {
    let screen = """
    Session usage
      No token usage recorded yet.
    Context window
      ░░░░░░░░░░░░░░░░░░░░      0%  (0 / 1M)
    Plan usage
      5h limit       ████░░░░░░░░░░░░░░░░  20% used  resets in 1h
      Weekly limit   ████████████░░░░░░░░  60% used  resets in 3d
      Monthly limit  ████████░░░░░░░░░░░░  40% used
                     kimi 15% · code 25%
    """
    let r = ClaudeLimits.parseKimiUsage(screen)
    #expect(r.map(\.kind) == ["session", "week", "month"])
    #expect(r[0].percent == 20 && r[0].resets == "in 1h")
    #expect(r[1].percent == 60 && r[2].percent == 40)
    let precise = ClaudeLimits.parseKimiUsage("Plan usage\n  Weekly limit  ███░░  42.5% used  resets in 1h 30m")
    #expect(precise == [.init(kind: "week", percent: 42.5, resets: "in 1h 30m")])
    #expect(ClaudeLimits.parseKimiUsage("Plan usage\n  No usage data available.").isEmpty)
}

@Test func programStatusReports() {
    var carry = ""
    let msg = Data("Needs approval".utf8).base64EncodedString()
    let out = ProgramStatus.scan("hi \u{1B}]7501;?\u{1B}\\ text \u{1B}]7501;state=blocked:kind=permission:msg=\(msg)\u{07} more \u{1B}]75", carry: &carry)
    #expect(out == [.query, .report(.init(id: nil, state: "blocked", kind: "permission", msg: "Needs approval"))])
    #expect(carry == "\u{1B}]75")
    let next = ProgramStatus.scan("01;state=working:id=sub/1\u{1B}\\", carry: &carry)
    #expect(next == [.report(.init(id: "sub/1", state: "working", kind: nil, msg: nil))])
    #expect(carry.isEmpty)
    #expect(ProgramStatus.parse("state=sleeping") == nil)
    #expect(ProgramStatus.parse("state=working:progress=140") == .report(.init(state: "working", progress: 100)))
    #expect(ProgramStatus.parse("state=done:progress=40") == .report(.init(state: "done")))   // only work in progress has one
    // ConEmu's bar: a percent, gone (0), indeterminate (3); one cut off at the end of a read is left out.
    #expect(ProgramStatus.conEmuProgress("a\u{1B}]9;4;1;42\u{07}b\u{1B}]9;4;0;0\u{1B}\\c\u{1B}]9;4;3;\u{07}\u{1B}]9;4;1;5") == [42, nil, nil])
    #expect(ProgramStatus.conEmuProgress("\u{1B}]9;notify me\u{07}").isEmpty)
    var d = StatusDetector(manifest: AgentManifest(id: "x", name: "X", command: "x"))
    d.program("blocked"); #expect(d.status == .waiting)
    d.program("error"); #expect(d.status == .error)
    d.output("lots of words here"); _ = d.tick(at: Date().addingTimeInterval(60)); #expect(d.status == .error)   // heuristics are off now
}

@Test func terminalTitleTopics() {
    var carry = ""
    // Claude Code's topic, split across two reads, after its own name.
    #expect(TerminalTitle.scan("\u{1B}]0;✳ Claude Code\u{07}text\u{1B}]0;✳ Ревью и оц", carry: &carry) == ["✳ Claude Code"])
    #expect(TerminalTitle.scan("енка приложения\u{07}", carry: &carry) == ["✳ Ревью и оценка приложения"])
    let claude = ["claude", "Claude Code", "Kelp"]
    #expect(TerminalTitle.topic("✳ Ревью и оценка приложения", names: claude) == "Ревью и оценка приложения")
    #expect(TerminalTitle.topic("◐ Claude Code", names: claude) == nil)
    // omp's spinner sits after its mark: every frame is the same topic.
    let omp = ["omp", "Oh My Pi", "Kelp"]
    #expect(TerminalTitle.topic("π ⠧ \u{F0297} CHEAT: Enable cheats", names: omp) == "π CHEAT: Enable cheats")
    #expect(TerminalTitle.topic("π ⠴ \u{F0297} CHEAT: Enable cheats", names: omp) == "π CHEAT: Enable cheats")
    // Others name themselves or the folder: no topic.
    #expect(TerminalTitle.topic("π - Kelp", names: ["pi", "Pi", "Kelp"]) == nil)
    #expect(TerminalTitle.topic("grok", names: ["grok", "Grok", "Kelp"]) == nil)
    #expect(TerminalTitle.topic("crush ~/projects/shop", names: ["crush", "Crush", "shop"]) == nil)
}

/// Codex running a long command prints nothing but its title's spinner, once a second: it's still working.
@Test func spinnerInTheTitleIsWork() throws {
    let t0 = Date()
    let codex = try #require(AgentManifest.presets.first { $0.id == "codex" })
    var d = StatusDetector(manifest: codex)
    d.input()
    d.output("• Ran docker compose exec backend python -m scripts.seed", at: t0)
    for (i, frame) in ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴"].enumerated() {
        let t = t0.addingTimeInterval(Double(i + 1))
        d.output("\u{1B}]0;\(frame) Seed the catalog | shop\u{07}\u{1B}[?25l\u{1B}[?25h", at: t)
        #expect(d.tick(at: t) == .working)
    }
    d.output("\u{1B}]0;Seed the catalog | shop\u{07}", at: t0.addingTimeInterval(7))   // the turn is over: no spinner
    #expect(d.tick(at: t0.addingTimeInterval(10)) == .done)
}

/// A TUI redraws its input line on every key: that echo isn't work, and a pause to think isn't a finished turn.
@Test func typingIsNotWork() throws {
    let t0 = Date()
    let codex = try #require(AgentManifest.presets.first { $0.id == "codex" })
    var d = StatusDetector(manifest: codex)
    d.input(typing: true, at: t0)
    d.output("› fix the login", at: t0.addingTimeInterval(0.1))
    #expect(d.status == .idle)
    #expect(d.tick(at: t0.addingTimeInterval(5)) == .idle)
    d.input(at: t0.addingTimeInterval(6))   // Return: now it works
    d.output("Reading the login form", at: t0.addingTimeInterval(6.2))
    #expect(d.status == .working)
}

@Test func approveInProseIsNotAQuestion() throws {
    let t0 = Date()
    let codex = try #require(AgentManifest.presets.first { $0.id == "codex" })
    var d = StatusDetector(manifest: codex)
    d.input(at: t0.addingTimeInterval(-10))
    d.output("I updated the approve button and its tests.\n", at: t0)
    #expect(d.tick(at: t0.addingTimeInterval(5)) == .done)
    var e = StatusDetector(manifest: codex)
    e.input(at: t0.addingTimeInterval(-10))
    e.output("Approve this change?\n", at: t0)
    #expect(e.tick(at: t0.addingTimeInterval(5)) == .waiting)
}

/// Grok redraws its opt-in banner with the screen after a turn: "allow … to" there is no question; "Allow … ?" is.
@Test func grokOptInBannerIsNotAQuestion() throws {
    let t0 = Date()
    let grok = try #require(AgentManifest.presets.first { $0.id == "grok" })
    var d = StatusDetector(manifest: grok)
    d.input(at: t0.addingTimeInterval(-10))
    d.output("Help improve Grok [Opt out] [Opt in] Off by default. Opt-in to allow SpaceXAI to retain coding data, e.g., prompts, "
        + "traces, & metrics, for training and debugging purposes. Change anytime via settings. Read Terms and Privacy Policy. "
        + "Worked for 5m 15s. Что дальше?", at: t0)
    #expect(d.tick(at: t0.addingTimeInterval(5)) == .done)
    var e = StatusDetector(manifest: grok)
    e.input(at: t0.addingTimeInterval(-10))
    e.output("Allow write to Sources/main.swift? [Allow once] [Deny]", at: t0)
    #expect(e.tick(at: t0.addingTimeInterval(5)) == .waiting)
}

/// After an update the new kelpd reads a question it inherited again, with its own patterns; one the agent reported stays.
@Test func anInheritedGuessIsReadAgainAReportIsNot() throws {
    let grok = try #require(AgentManifest.presets.first { $0.id == "grok" })
    let banner = "Worked for 4m0s. Opt-in to allow SpaceXAI to retain coding data, for training and debugging purposes."
    var guessed = StatusDetector(manifest: grok)
    guessed.adopted(.waiting, screen: banner)
    #expect(guessed.status == .done)
    var reported = StatusDetector(manifest: grok)
    reported.adopted(.waiting, screen: "\u{1B}]7501;state=blocked:kind=permission\u{07}" + banner)
    #expect(reported.status == .waiting)
}

/// A redraw of borders and a spinner, each ended by ESC ( B, has no words.
@Test func characterSetSwitchesAreNotWords() {
    let redraw = "\u{1B}[23;3H┃\u{1B}[2C◆\u{1B}[55;7H\u{1B}(B\u{1B}[m┃\u{1B}(B┃⠴\u{1B}(B"
    #expect(StatusDetector.stripANSI(redraw) == " ┃ ◆ ┃┃⠴")   // each cursor move keeps its gap
    #expect(!StatusDetector.hasWords(StatusDetector.stripANSI(redraw)))
}

@Test func agentTrustIsReadFromEachAgentsOwnConfig() throws {
    let home = tmp().path
    let fm = FileManager.default
    for d in ["/p/known/desk", "/p/other", "/.codex", "/.gemini", "/.kimi-code/workspace-trust", "/profile"] {
        try fm.createDirectory(atPath: home + d, withIntermediateDirectories: true)
    }
    try #"{"projects":{"\#(home)/p/known":{"hasTrustDialogAccepted":true},"\#(home)/p/other":{"hasTrustDialogAccepted":false}}}"#
        .write(toFile: home + "/.claude.json", atomically: true, encoding: .utf8)
    try "model = \"x\"\n[projects.\"\(home)/p/known\"]\ntrust_level = \"trusted\"\n[projects.\"\(home)/p/other\"]\ntrust_level = \"untrusted\"\n"
        .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
    try #"{"\#(home)/p/known/desk":"TRUST_PARENT","\#(home)/p/other":"DO_NOT_TRUST"}"#.write(toFile: home + "/.gemini/trustedFolders.json", atomically: true, encoding: .utf8)
    try #"{"root":"\#(home)/p/known","trustedAt":1}"#.write(toFile: home + "/.kimi-code/workspace-trust/wd_known", atomically: true, encoding: .utf8)
    for agent in ["claude", "codex", "gemini", "kimi"] {
        #expect(AgentTrust.trusts(agent: agent, folders: [home + "/p/known"], home: home), "\(agent)")
        #expect(AgentTrust.trusts(agent: agent, folders: [home + "/p/known/desk"], home: home), "\(agent): a folder inside a trusted one")
        #expect(!AgentTrust.trusts(agent: agent, folders: [home + "/p/other"], home: home), "\(agent): explicitly not trusted")
        #expect(!AgentTrust.trusts(agent: agent, folders: [home + "/p/knownother"], home: home), "\(agent): a name that only starts the same")
    }
    #expect(AgentTrust.trusts(agent: "claude", folders: [home + "/p/new", home + "/p/known"], home: home))   // the project's main folder counts
    #expect(!AgentTrust.trusts(agent: "cursor", folders: [home + "/p/known"], home: home))                  // no way to know: never
    // An account profile reads its own config.
    try #"{"projects":{}}"#.write(toFile: home + "/profile/.claude.json", atomically: true, encoding: .utf8)
    #expect(!AgentTrust.trusts(agent: "claude", folders: [home + "/p/known"], env: ["CLAUDE_CONFIG_DIR": home + "/profile"], home: home))
}

/// The test process is isolated as it loads, before this (or any) test touches anything: run alone, a target still
/// can't read the user's own agent config or keychain.
@Test func theProcessIsIsolatedBeforeAnyTestRuns() {
    let env = ProcessInfo.processInfo.environment
    #expect(env["KELP_TEST_ISOLATED"] == "1")
    for key in ["KELP_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] { #expect(env[key]?.hasPrefix("/tmp/kr-") == true, "\(key)") }
    #expect(env["KELP_KEYCHAIN_SERVICE"]?.hasPrefix("dev.kelp.tests.") == true && env["GIT_CONFIG_GLOBAL"] == "/dev/null")
}

/// Paused (or ended) stays so: what the program prints or reports while it's being stopped doesn't make it "working"
/// again (which would then be saved as ended, and the session couldn't resume).
@Test func aPausedSessionStaysPausedWhileItsProgramStops() throws {
    let codex = try #require(AgentManifest.presets.first { $0.id == "codex" })
    var d = StatusDetector(manifest: codex)
    d.input(at: Date(timeIntervalSince1970: 0))   // typed into: the heuristics are on
    d.override(.hibernated)
    d.output("Saving the conversation before quitting", at: Date(timeIntervalSince1970: 100))
    #expect(d.status == .hibernated)
    d.program("working"); d.hook("done")
    #expect(d.status == .hibernated)
}

/// Attached again to an agent that kept running (tmux on a host): its redraw is no turn however late it comes (a slow
/// ssh), and what it prints after the redraw's seconds is work again.
@Test func aLateRedrawAfterAttachingIsNoTurn() {
    let m = AgentManifest(id: "w", name: "W", command: "w")
    var d = StatusDetector(manifest: m)
    let t0 = Date()
    d.attachedToRunning(at: t0)
    d.output("did the work and more words", at: t0.addingTimeInterval(10))   // the redraw, 10 s on
    d.output("still the redraw's words", at: t0.addingTimeInterval(12))
    #expect(d.status == .idle)
    d.output("new work after it", at: t0.addingTimeInterval(16))
    #expect(d.status == .working)
}

/// A title split across two reads (a program setting its window title as it works) isn't words: the half sequence is
/// kept until the rest of it comes.
@Test func aTitleSplitAcrossReadsIsNoWork() {
    var d = StatusDetector(manifest: AgentManifest(id: "w", name: "W", command: "w"))
    let t0 = Date()
    d.input(at: t0)
    d.output("\u{1B}]0;Building the", at: t0.addingTimeInterval(5))
    d.output(" whole app\u{07}", at: t0.addingTimeInterval(5.1))
    #expect(d.status == .idle)
    #expect(StatusDetector.wholeSequences("ok\u{1B}[31").rest == "\u{1B}[31" && StatusDetector.wholeSequences("ok\u{1B}[31m").rest.isEmpty)
}

@Test func aCutShortTurnIsIdleAndItsRedrawIsNoWork() {
    var d = StatusDetector(manifest: AgentManifest.presets.first { $0.id == "codex" }!)
    let t = Date()
    d.input(at: t)
    d.output("Working on the tests for the login form", at: t)
    #expect(d.status == .working)
    d.interrupted(at: t.addingTimeInterval(1))
    d.output("Conversation interrupted again, more words here", at: t.addingTimeInterval(2))
    #expect(d.status == .idle)
}

@Test func copilotUsageScreenParses() {
    let screen = """
    AI Credits 0 (14s)
    Plan ■■■■■■■■■■■■■■■■■■■■ 2% used 5 / 200 AIC ─╮╭╮
    ─╯╰╯
    """
    #expect(ClaudeLimits.parseCopilotUsage(screen) == [.init(kind: "plan", percent: 2, resets: nil)])
    let two = ClaudeLimits.parseCopilotUsage("│ Plan ███░░ 40.5% used resets in 3d │\n│ Plan ███░░ 41% used resets in 3d │")
    #expect(two == [.init(kind: "plan", percent: 41, resets: "in 3d")])   // the last redraw wins
    #expect(ClaudeLimits.parseCopilotUsage("Session: 0 AIC used").isEmpty)
}

@Test func cursorUsageScreenParses() {
    let screen = """
    Usage • Free Resets Nov 23
    Monthly plan and on-demand usage
    Category Current Usage
    Included 0% used ░░░░░░░░░░
    Auto 12.5% used ██░░░░░░░░
    API 0% used ░░░░░░░░░░
    On-Demand Disabled ————————
    """
    let r = ClaudeLimits.parseCursorUsage(screen)
    #expect(r.map(\.kind) == ["month", "Auto", "API"])
    #expect(r[1].percent == 12.5 && r[1].resets == "Nov 23")
    #expect(ClaudeLimits.parseCursorUsage("Loading usage data...").isEmpty)
}

@Test func cursorLimitHitParses() {
    let screen = """
      Error: You've hit your usage limit
      chatMessage: *You've hit your free requests limit. [Upgrade to
      Pro](https://www.cursor.com/api/auth/checkoutDeepControl?tier=pro) for more usage. Your usage limits will reset when your monthly cycle ends on 11/23/2026.*
    """
    #expect(ClaudeLimits.parseCursorLimitHit(screen) == .init(kind: "month", percent: 100, resets: "Nov 23"))
    #expect(ClaudeLimits.parseCursorLimitHit("Error: You've hit your usage limit")?.resets == nil)
    #expect(ClaudeLimits.parseCursorLimitHit("→ Plan, search, build anything") == nil)
}

/// What an agent prints when its plan stopped it: today's Claude Code, an older one, Codex with and without a date.
@Test func limitHitsAreRead() throws {
    let five = try #require(ClaudeLimits.parse("⎿  You've hit your 5-hour limit · resets 3:40pm (Europe/Helsinki) · progress saved").first)
    #expect(five == .init(kind: "5-hour", percent: 100, resets: "3:40pm"))
    #expect(ClaudeLimits.parse("You've hit your limit · resets Oct 20 at 5am").first == .init(kind: "usage", percent: 100, resets: "Oct 20 at 5am"))
    #expect(ClaudeLimits.parse("You've hit your weekly limit").first == .init(kind: "weekly", percent: 100, resets: nil))
    #expect(ClaudeLimits.parse("5-hour limit reached · resets 3pm").first?.percent == 100)
    #expect(ClaudeLimits.parse("You've used 80% of your weekly limit").first?.percent == 80)

    let codex = "■ You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus),\n  or try again at Oct 30,\n  2026 3:40 PM."
    #expect(ClaudeLimits.parseCodexLimitHit(codex) == .init(kind: "usage", percent: 100, resets: "Oct 30, 2026 3:40 PM"))
    #expect(ClaudeLimits.parseCodexLimitHit("You've hit your usage limit.")?.resets == nil)
    #expect(ClaudeLimits.parseCodexLimitHit("Working (12s • esc to interrupt)") == nil)

    // Only a StopFailure says so: the same words in a notification or a reply are words.
    let failure: JSONValue = .obj(["hook_event_name": "StopFailure", "error": "rate_limit", "last_assistant_message": "You've hit your session limit · resets 7pm"])
    let said = try #require(SessionHook.notification(of: failure))
    #expect(Hooks.limitHit(said) == .init(kind: "session", percent: 100, resets: "7pm"))
    #expect(SessionHook.notification(of: .obj(["hook_event_name": "Stop"])) == nil)
    #expect(SessionHook.notification(of: .obj(["message": "Claude needs your permission"]))?["message"]?.string == "Claude needs your permission")
    #expect(Hooks.limitHit(.obj(["notification_type": "stop_failure", "message": "API Error: 500"])) == nil)
    #expect(Hooks.limitHit(.obj(["message": "You've hit your session limit"])) == nil)
}

/// Every preset an installer exists for offers it; the ones that need npm or Homebrew say so, so the app can check first.
@Test func presetsWithAnInstallerOfferIt() throws {
    func installed(_ id: String) throws -> AgentManifest { AgentManifest.withInstall(try #require(AgentManifest.presets.first { $0.id == id })) }
    for id in ["pi", "grok", "antigravity", "kilo", "goose", "kiro"] { #expect(try installed(id).install != nil, "\(id) installs") }
    #expect(try installed("kilo").installNeeds == "npm" && installed("codex").installNeeds == "npm" && installed("crush").installNeeds == "brew")
    #expect(try installed("claude").installNeeds == nil && installed("pi").installNeeds == nil && installed("goose").installNeeds == nil)
    #expect(try installed("goose").install?.contains("CONFIGURE=false") == true)
}
