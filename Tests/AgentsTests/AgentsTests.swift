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

@Test func hooksSettingsIsValidJSON() throws {
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(Hooks.settingsJSON().utf8))
    #expect(v["hooks"]?["Stop"] != nil)
    #expect(v["hooks"]?["PreToolUse"]?.array?.first?["matcher"]?.string == "AskUserQuestion")
}

@Test func idleReminderIsNotAQuestion() {
    #expect(Hooks.isIdleReminder(.obj(["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])))
    #expect(!Hooks.isIdleReminder(.obj(["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])))
}

@Test func stopWithBackgroundAgentsIsNotDone() {
    func stop(_ types: [String]) -> JSONValue { .obj(["background_tasks": .array(types.map { .obj(["type": .string($0)]) })]) }
    #expect(Hooks.hasBackgroundWork(stop(["subagent", "shell"])))
    #expect(Hooks.hasBackgroundWork(stop(["workflow"])))
    #expect(!Hooks.hasBackgroundWork(stop(["shell", "monitor"])))
    #expect(!Hooks.hasBackgroundWork(stop([])))
    #expect(!Hooks.hasBackgroundWork(.obj([:])))   // older Claude Code: no field
}

@Test func stripKeepsWordGapsFromCursorMoves() {
    let raw = "\u{1B}[2GQuick\u{1B}[8Gsafety\u{1B}[15Gcheck: one\u{1B}[30Gyou trust?\n\u{1B}[2G\u{1B}[38;2;177;185;249m❯\u{1B}[4GNo,\u{1B}[8Gexit\u{1B}[39m\n\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust\n"
    let t = StatusDetector.stripANSI(raw)
    #expect(t.contains("one you trust"))
    #expect(AgentManifest.AutoAnswer.optionAtCursor(t) == "No, exit")
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
    #expect(ClaudeLimits.parse("nothing to see").isEmpty)
}

@Test func claudeUsageScreenParses() {
    let screen = """
    Settings    Status   Config      Usage      Stats
    Current session
    █                                                    2% used
    Resets 7:40am (Europe/Helsinki)
    Current week (all models)
    █████████████████████████████████████████            82% used
    Resets Oct 20 at 5am (Europe/Helsinki)
    Scanning local sessions…
    Current week (Fable)
    0% used
    Resets Oct 20 at 5am (Europe/Helsinki)
    """
    let r = ClaudeLimits.parseUsageScreen(screen)
    #expect(r.map(\.kind) == ["session", "week", "week · Fable"])
    #expect(r[1].percent == 82 && r[1].resets == "Oct 20 at 5am")
    #expect(r[0].resets == "7:40am")
}

@Test func resumeFindsThisConversationNotTheLatest() throws {
    let claude = try #require(AgentManifest.presets.first { $0.id == "claude" })
    let pinned = ["claude", "--settings", "h.json", "--session-id", "abc"]
    #expect(claude.resuming(pinned) == ["claude", "--settings", "h.json", "--resume", "abc"])
    #expect(claude.resuming(claude.resuming(pinned)) == claude.resuming(pinned))
    #expect(claude.resuming(["claude"]) == ["claude", "--continue"])   // sessions from before ids were pinned
    #expect(claude.resumes(["claude", "--resume", "x"]))
}

@Test func hookedAgentsDontGuessFromOutput() throws {
    let claude = try #require(AgentManifest.presets.first { $0.id == "claude" })
    var d = StatusDetector(manifest: claude)
    d.output("✻ redraw", at: Date())
    #expect(d.status == .idle)
    d.hook("working"); #expect(d.status == .working)
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
    let grok = "Context usage │ Usage limit │ Session info\n Weekly limit (X Premium)\n ██████░░░░ 45%\n Resets: October 24, 19:36\n Loading session usage…"
    #expect(ClaudeLimits.parseGrokUsage(grok) == [.init(kind: "week", percent: 45, resets: "October 24, 19:36")])
    let framed = "│ Weekly limit (X Premium)          │\n│ ██████░░░░ 45%                    │\n│ Resets: October 24, 19:36         │"
    #expect(ClaudeLimits.parseGrokUsage(framed).first?.percent == 45)
    let agy = """
    └ Models & Quota
    GEMINI MODELS
    Models within this group: Gemini Flash, Gemini Pro
    Weekly Limit Remaining
    [████████████] 88.00%
    Quota available
    CLAUDE AND GPT MODELS
    Models within this group: Claude Opus, Claude Sonnet, GPT-OSS
    Within each group, models share a weekly limit.
    """
    #expect(ClaudeLimits.parseAntigravityUsage(agy) == [.init(kind: "Gemini week", percent: 12, resets: nil)])
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

@Test func agentTrustIsReadFromEachAgentsOwnConfig() throws {
    let home = tmp().path
    let fm = FileManager.default
    for d in ["/p/known/desk", "/p/other", "/.codex", "/.gemini", "/profile"] { try fm.createDirectory(atPath: home + d, withIntermediateDirectories: true) }
    try #"{"projects":{"\#(home)/p/known":{"hasTrustDialogAccepted":true},"\#(home)/p/other":{"hasTrustDialogAccepted":false}}}"#
        .write(toFile: home + "/.claude.json", atomically: true, encoding: .utf8)
    try "model = \"x\"\n[projects.\"\(home)/p/known\"]\ntrust_level = \"trusted\"\n[projects.\"\(home)/p/other\"]\ntrust_level = \"untrusted\"\n"
        .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
    try #"{"\#(home)/p/known/desk":"TRUST_PARENT","\#(home)/p/other":"DO_NOT_TRUST"}"#.write(toFile: home + "/.gemini/trustedFolders.json", atomically: true, encoding: .utf8)
    for agent in ["claude", "codex", "gemini"] {
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
