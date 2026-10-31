import Foundation
import Testing
import Core
import Agents
@testable import Daemon

/// An agent that reports itself through hooks (Claude Code's), as the daemon reads them.
private func hooked() -> LiveSession.State {
    LiveSession.State(record: Session(cwd: "/", command: "claude", agent: "claude"),
                      manifest: AgentManifest(id: "claude", name: "Claude Code", command: "claude", hooks: .settingsFlag("--settings")),
                      logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "s"))
}

/// Claude Code compacts a conversation that sits idle ("Compacted while idle…", trigger "auto"): no turn follows to end it,
/// so the row must not turn working (it stayed so for hours, with the Mac kept awake) nor done (a notification for nothing).
@Test func anIdleCompactionLeavesTheRowAsItWas() {
    var s = hooked()
    s.hook("working"); s.hook("done"); _ = s.sync()
    s.record.summary = "Asked what to do next"; s.record.unread = false
    s.hook("compacting", trigger: "auto")
    #expect(s.sync() == nil && s.record.status == .done)
    #expect(s.record.summary == "Compacting the conversation…")
    s.hook("compacted")
    #expect(s.sync() == nil && s.record.status == .done && !s.record.unread)
    #expect(s.record.summary == "Asked what to do next")
}

/// One in the middle of a turn goes on with it; a /compact the user typed ends at the prompt.
@Test func aCompactionDuringATurnCarriesOnAndATypedOneEndsIdle() {
    var s = hooked()
    s.hook("working"); _ = s.sync()
    s.hook("compacting", trigger: "auto")
    s.hook("compacted"); _ = s.sync()
    #expect(s.record.status == .working && s.record.summary.isEmpty)
    s.hook("done"); _ = s.sync()
    s.hook("compacting", trigger: "manual"); _ = s.sync()
    #expect(s.record.status == .working && s.record.summary == "Compacting the conversation…")
    s.hook("compacted"); _ = s.sync()
    #expect(s.record.status == .idle && s.record.summary.isEmpty)
}

/// A row that says working while the screen stood still and no hook came is released: a Stop it missed. A Stop held for
/// what the agent waits for is quiet by design, so it gets longer; a live screen or a hook starts the wait again.
@Test func aWorkingRowThatWentQuietIsReleased() {
    var s = hooked(), t = s.lastLifeUp
    s.hook("working"); _ = s.sync()
    t = s.lastLifeUp
    s.releaseStale(at: t + 120); #expect(s.detector.status == .working)
    s.lastLifeUp = t + 100   // it printed
    s.releaseStale(at: t + 250); #expect(s.detector.status == .working)
    s.releaseStale(at: t + 290)
    #expect(s.sync() != nil && s.record.status == .done)
    #expect(s.detector.source == "no sign of life for 180 s")   // no hook said so

    s.hook("working"); s.holding = true   // a Stop held for its subagents
    t = s.lastLifeUp
    s.record.goal = "tests pass"
    s.releaseStale(at: t + 1000); #expect(s.detector.status == .working)
    s.releaseStale(at: t + 1900)
    #expect(s.detector.status == .done && s.record.goal == nil)
}

/// `kelp report clear` takes back what an agent's row said. With hooks the status is theirs: it went on working, and its row
/// said Idle until the next hook.
@Test func aClearedReportLeavesTheStatusToTheHooks() {
    var s = hooked()
    s.hook("working"); _ = s.sync()
    s.apply(.init(state: "working", msg: "Migrating table 3 of 10", progress: 30))
    s.apply(.init(state: "clear"))
    #expect(s.sync() == nil && s.detector.status == .working)
    #expect(s.record.summary.isEmpty && s.record.progress == nil)
}

/// A tool of the main thread after its turn ended: it went on with no prompt (a Stop hook that blocked, as /goal's first step
/// does). A subagent's says nothing of the main thread, and a row held as working stays held.
@Test func aToolAfterTheTurnEndedMeansItWentOn() {
    var s = hooked()
    s.hook("done"); _ = s.sync()
    #expect(s.record.status == .done)
    s.tool("PreToolUse", agent: "a1")
    s.tool("PostToolUse", agent: nil)
    #expect(s.sync() == nil)
    s.tool("PreToolUse", agent: nil)
    #expect(s.sync()?.status == .working)
    #expect(s.detector.source == "a tool started after its turn ended")
    s.holding = true
    s.tool("PreToolUse", agent: nil)
    #expect(s.holding)
}

/// A permission dialog answered anywhere ends with its batch of tools. As Claude Code 2.1.316 sends it, two parallel dialogs:
/// the first tool's PostToolUse comes with the second still open, so only the batch counts; and a subagent's stays its own.
@Test func aPermissionIsAnsweredWhenItsToolsRan() {
    var s = hooked()
    s.hook("working"); _ = s.sync()
    s.hook("waiting", asker: ""); s.tool("PreToolUse", agent: nil); s.hook("waiting", asker: ""); _ = s.sync()
    s.tool("PostToolUse", agent: nil)
    #expect(s.sync() == nil && s.record.status == .waiting)
    s.tool("PostToolBatch", agent: "other")
    #expect(s.sync() == nil)
    s.tool("PostToolBatch", agent: nil)
    #expect(s.sync()?.status == .working)
    #expect(s.detector.source == "the tools it asked about ran")

    s.hook("waiting", asker: ""); s.hook("waiting", asker: "a1"); _ = s.sync()
    s.tool("PostToolBatch", agent: nil)
    #expect(s.sync() == nil)   // the subagent's dialog is still open
    s.tool("PostToolBatch", agent: "a1")
    #expect(s.sync()?.status == .working)

    s.hook("waiting"); _ = s.sync()   // a Notification's question: no batch answers that
    s.tool("PostToolBatch", agent: nil)
    #expect(s.sync() == nil && s.record.status == .waiting)
}

/// A quiet row with a menu on screen is a question whose hook never came: it asks, and what its turn was held for stays. A menu
/// answered since (the newer cursor is the input box's) doesn't count.
@Test func aQuietRowWithAMenuOnScreenAsks() {
    var s = hooked()
    s.hook("working"); _ = s.sync()
    s.holding = true; s.record.goal = "tests pass"
    s.ring = Data("Do you want to proceed?\r\n❯ 1. Yes\r\n  2. No\r\n".utf8)
    s.releaseStale(at: s.lastLifeUp + 1900)
    #expect(s.sync()?.status == .waiting)
    #expect(s.detector.source == "no sign of life for 1800 s, and a menu on screen")
    #expect(s.record.unread && s.record.goal == "tests pass")

    s.hook("working"); _ = s.sync()
    s.ring += Data("\r\n❯ fix the login page\r\n".utf8)
    s.releaseStale(at: s.lastLifeUp + 200)
    #expect(s.sync()?.status == .done)
}

/// What no hook reports (a plain shell, a heuristic agent) isn't released by a quiet screen: its status comes from the screen.
@Test func anAgentWithoutHooksIsNotReleased() {
    var s = LiveSession.State(record: Session(cwd: "/", command: "aider", agent: "aider"),
                              manifest: AgentManifest(id: "aider", name: "Aider", command: "aider"), logSize: 0, callbacks: .init(),
                              trail: .init(history: tmp(), session: "s"))
    s.detector.override(.working)
    s.releaseStale(at: s.lastLifeUp + 5000)
    #expect(s.detector.status == .working)
}

/// Notifications that ask nothing leave the row alone (a finished background agent turned an idle row into "needs you").
@Test func aNotificationThatAsksNothingIsNoQuestion() async throws {
    let w = try await world(); defer { w.d.stop() }
    let desk = try await firstDesk(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(desk.id), "command": "sleep 30"]), as: Session.self)
    func status() async throws -> AgentStatus? { try await w.c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status }
    func notify(_ type: String) async throws {
        _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "waiting",
                                                       "notification": .obj(["notification_type": .string(type), "message": "x"])]))
    }
    _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "done"]))
    #expect(try await waitFor { try await status() == .done })
    for type in ["agent_completed", "push_notification", "computer_use_exit", "quota_auto_resume_fired"] { try await notify(type) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await status() == .done)
    try await notify("permission_prompt")
    #expect(try await waitFor { try await status() == .waiting })
    _ = try await w.c.call("session.kill", .obj(["id": .string(s.id)]))
}

/// Claude Code's PermissionRequest makes the row ask at once, saying what it would run; the vague Notification that
/// follows six seconds later leaves that text.
@Test func aPermissionRequestAsksAtOnceAndKeepsItsText() async throws {
    let w = try await world(); defer { w.d.stop() }
    let desk = try await firstDesk(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(desk.id), "command": "sleep 30"]), as: Session.self)
    func row() async throws -> Session? { try await w.c.call("session.list", as: [Session].self).first { $0.id == s.id } }
    _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "waiting", "notification": .obj([
        "notification_type": "permission_request", "tool_name": "Bash", "tool_input": .obj(["command": "npm test"])])]))
    #expect(try await waitFor { try await row()?.status == .waiting })
    #expect(try await row()?.summary == "Allow npm test?")
    _ = try await w.c.call("session.hook", .obj(["id": .string(s.id), "event": "waiting", "notification": .obj([
        "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])]))
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await row()?.summary == "Allow npm test?")
    _ = try await w.c.call("session.kill", .obj(["id": .string(s.id)]))
}

/// Answering a permission menu turns the row back to working: Return and ⇧Tab as the kitty protocol sends them too
/// (Claude Code turns it on), and the row stayed "needs you" until the turn ended.
@Test func menuAnswersAreSeenInKittyKeyboardMode() {
    for k in ["\r", "2", "\u{1B}[Z", "\u{1B}[13u", "\u{1B}[9;2u"] { #expect(LiveSession.answersMenu(Data(k.utf8)), "\(k.debugDescription)") }
    for k in ["\u{1B}[B", "\u{1B}[9u", "\u{1B}[13;2u", "a", "0"] { #expect(!LiveSession.answersMenu(Data(k.utf8)), "\(k.debugDescription)") }
}
