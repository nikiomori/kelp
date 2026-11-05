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

/// An agent in tmux on a host: no hooks here, it writes its status to the terminal (`Hooks.hostSettingsJSON`).
private func onHost() -> LiveSession.State {
    var r = Session(cwd: "/", command: "claude", agent: "claude")
    r.tmux = "kelp_agent"
    return LiveSession.State(record: r, manifest: AgentManifest(id: "claude", name: "Claude Code", command: "claude"),
                             logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "s"))
}

/// A new turn doesn't go on showing what the last one said; a compaction under way still says so.
@Test func aPromptClearsTheLastTurnsWords() {
    var s = hooked()
    s.record.summary = "Counted 356 files"
    s.hook("working")
    #expect(s.record.summary == "")
    s.hook("compacting", trigger: "auto")
    let compacting = s.record.summary
    s.hook("working")
    #expect(!compacting.isEmpty && s.record.summary == compacting)
}

/// A Stop that never reached Kelp, or a turn cut short, leaves nothing to say so on a host either: the same wait ends it,
/// longer while a subagent runs, as nothing prints then. Without it the row kept the Mac awake until the next prompt.
@Test func aHostsWorkingRowThatWentQuietIsReleased() {
    var s = onHost()
    s.apply(.init(state: "working")); _ = s.sync()
    let t = s.lastLifeUp
    s.record.subagents = ["a": ""]
    s.releaseStale(at: t + 200); #expect(s.detector.status == .working)
    s.record.subagents = nil
    s.releaseStale(at: t + 200); #expect(s.detector.status == .done)
}

/// On a host, an answer typed at a dialog is the same as here, and one that says No gets its turn read off the screen.
@Test func aHostsDialogAnsweredStopsAsking() {
    var s = onHost()
    s.apply(.init(state: "blocked")); _ = s.sync()
    #expect(s.saysItself && s.record.status == .waiting)
    // Hooks that never spoke, or no status from the host yet: the screen says, and an answer settles once it's quiet.
    #expect(!onHost().saysItself)
    var silent = hooked()
    silent.detector.hooksSilent()
    #expect(!silent.saysItself)
}

/// A program that only reports what it's told to (`kelp report working`, a long quiet script) isn't released: nothing
/// says its turns end.
@Test func aReportingShellStaysAsItSaid() {
    var s = LiveSession.State(record: Session(cwd: "/", command: "sh", agent: "custom"), manifest: AgentManifest(id: "custom", name: "x", command: "sh"),
                              logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "s"))
    s.apply(.init(state: "working")); _ = s.sync()
    s.releaseStale(at: s.lastLifeUp + 5000)
    #expect(s.detector.status == .working)
}

/// Five edits, each asked about, are one turn: its snapshot isn't taken again at each answer, and what came before the
/// last dialog still counts.
@Test func aDialogDoesntEndTheTurn() {
    var s = hooked()
    #expect(s.turnMoved(to: .working) == (true, false))
    #expect(s.turnMoved(to: .waiting) == (false, false))
    #expect(s.turnMoved(to: .working) == (false, false))
    #expect(s.turnMoved(to: .done) == (false, true))
    #expect(s.turnMoved(to: .waiting) == (false, false))   // no turn to end
}

/// Esc in an empty box leaves it empty: a report waiting for that would wait for the next Return, and nothing says so.
@Test func escLeavesTheBoxEmpty() {
    var s = hooked()
    s.boxEmpty = true
    _ = s.noteTyping(Data([0x1B]))
    _ = s.noteTyping(Data("\u{1B}[27u".utf8))
    #expect(s.boxEmpty)
    _ = s.noteTyping(Data("a".utf8))
    #expect(!s.boxEmpty)
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
    let workspace = try await firstWorkspace(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(workspace.id), "command": "sleep 30"]), as: Session.self)
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
    let workspace = try await firstWorkspace(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(workspace.id), "command": "sleep 30"]), as: Session.self)
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

/// Hooks can be off without Kelp being told (disableAllHooks, a managed policy, `kelp` not on PATH). A line went in and none
/// came: the row is read off the screen, says why, and a hook that comes after all takes that back.
@Test func anAgentWhoseHooksStaySilentIsReadOffTheScreen() {
    var s = hooked()
    s.hooksSilent(at: 1e9)   // nothing was sent yet: a resumed agent sits at its prompt, and hooks have nothing to say
    #expect(s.detector.hooked && s.sync() == nil)
    s.expectHook()
    let sent = s.lineSentUp
    #expect(sent != nil)
    s.hooksSilent(at: (sent ?? 0) + 5)
    #expect(s.detector.hooked)
    s.hooksSilent(at: (sent ?? 0) + 16)
    #expect(!s.detector.hooked && s.sync()?.status == .working && s.record.summary == LiveSession.State.noHooks)
    s.detector.output("still working on it")
    #expect(s.record.status == .working)

    s.spoke(); s.hook("done")
    #expect(s.detector.hooked && s.sync()?.status == .done && s.record.summary.isEmpty)
    s.expectHook()
    #expect(s.lineSentUp == nil)   // they spoke once: an agent between turns isn't suspect
}

/// A question a program without hooks asked and the user answered: the row doesn't wait for words that may never come.
@Test func anAnswerToAnAgentWithoutHooksEndsItsQuestion() {
    var d = StatusDetector(manifest: AgentManifest(id: "a", name: "A", command: "a", waitingPatterns: ["Allow\\?"]))
    d.input()
    d.output("Allow?", at: Date(timeIntervalSinceReferenceDate: 1000))
    #expect(d.tick(at: Date(timeIntervalSinceReferenceDate: 2000)) == .waiting)
    d.answered(at: Date(timeIntervalSinceReferenceDate: 3000))
    #expect(d.status == .working)
    d.input()
    #expect(d.tick(at: Date(timeIntervalSinceReferenceDate: 4000)) == .done)
}

/// Claude Code blinks a dot beside the tool a dialog is about, and within 20 s the menu is out of the last bytes though it's
/// still on screen. Seen with 2.1.316: Allow in a notification found no menu, and `kelp send`, seeing none, typed its text
/// and pressed Enter, which said yes to the permission.
@Test func aDialogHoldsTextBackHoweverLongADotBlinksBesideIt() throws {
    var s = hooked()
    s.startedUp = true; s.dialogSettled = true
    s.ring = Data("Do you want to proceed?\r\n ❯ 1. Yes\r\n   2. No\r\n Esc to cancel · Tab to amend\r\n".utf8)
    for _ in 0..<500 { s.ring.append(Data("\u{1B}[3;1H\u{1B}[38;2;1;1;1m⏺\u{1B}[3;1H\u{1B}[0m ".utf8)) }
    #expect(!StartupQuestion.menuOpen(s.screen(1500)))
    s.hook("waiting"); _ = s.sync()
    #expect(s.menuOpen() && s.menuScreen().contains("2. No"))
    #expect(!s.readyForText(submits: true) && !s.readyForText(submits: false))

    // Allow from a notification: the row works from then on, and the keys still need the menu.
    s.steering = (try NSRegularExpression(pattern: "Yes"), Date(), .distantPast, nil)
    s.detector.override(.working); _ = s.sync()
    #expect(s.menuOpen() && !s.readyForText(submits: true))
    s.steering = nil; s.hook("waiting"); _ = s.sync()

    // A hook said so and no menu can be read (an AskUserQuestion, say): Enter would still answer it.
    s.ring = Data("Which one?".utf8)
    #expect(!s.menuOpen() && !s.readyForText(submits: true))
    s.hook("working"); _ = s.sync()
    #expect(s.readyForText(submits: true))
}

/// A pause would end a question unanswered, so an agent that asks stays, however long nobody looks; one that finished goes.
@Test func anAgentThatAsksIsntPaused() async throws {
    let sleepy = AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "sleep 30", "x"], resumeArgs: ["--resume"])
    let w = try await world(agents: [sleepy]); defer { w.d.stop() }
    let wt = try await workspace(w, "h")
    func started() async throws -> Session { try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "sleepy"]), as: Session.self) }
    func status(_ s: Session) async throws -> AgentStatus? { try await w.c.call("session.list", as: [Session].self).first { $0.id == s.id }?.status }
    let asks = try await started(), done = try await started()
    _ = try await w.c.call(SessionHook(id: asks.id, event: "waiting"))
    _ = try await w.c.call(SessionHook(id: done.id, event: "done"))
    try await hibernate(after: 0.03, w.c)   // ~2 s
    #expect(try await waitFor(15) { try await status(done) == .paused })
    #expect(try await status(asks) == .waiting)
    try await hibernate(after: 0, w.c)
}

/// At rest an agent with hooks still redraws (Claude Code's "Checking for updates"): that isn't work, so it pauses all the same.
@Test func anAgentThatRedrawsAtRestStillPauses() async throws {
    let ticks = AgentManifest(id: "ticks", name: "Ticks", command: "/bin/zsh", args: ["-c", "while :; do echo tick; sleep 0.2; done", "x"],
                              hooks: .settingsFlag("--settings"), resumeArgs: ["--resume"])
    let w = try await world(agents: [ticks]); defer { w.d.stop() }
    let wt = try await workspace(w, "ticks")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "ticks"))
    #expect(try await waitFor { try await w.c.call(SessionRead(id: s.id)).contains("tick") })
    _ = try await w.c.call(SessionHook(id: s.id, event: "done"))
    try await hibernate(after: 0.03, w.c)   // ~2 s
    #expect(try await waitFor(15) { try await w.c.call(SessionList()).first { $0.id == s.id }?.status == .paused })
    try await hibernate(after: 0, w.c)
}

/// Two dialogs in one batch: Claude Code shows them one after another and says nothing for the second once the first is
/// answered, so a key leaves the row asking. A batch through says all of them are.
@Test func aKeyAnswersOneDialogOfABatch() {
    var s = hooked()
    s.hook("working"); s.hook("waiting", asker: ""); s.hook("waiting", asker: ""); _ = s.sync()
    #expect(!s.answeredOne() && s.answeredOne())
    s.hook("waiting", asker: ""); s.hook("waiting", asker: ""); _ = s.sync()
    s.tool("PostToolBatch", agent: nil)
    #expect(s.asking.isEmpty && s.sync()?.status == .working)
}

/// A turn cut short outside Kelp sends no hook: after the quiet, what it printed decides. A menu still open keeps it asking.
@Test func aTurnCutShortElsewhereGoesIdleWhenItsScreenSaysSo() {
    for status in ["working", "waiting"] {
        var s = hooked()
        s.hook(status); _ = s.sync()
        s.ring = Data("⏺\r\n Interrupted · What should Claude do instead?\r\n ❯ \r\n".utf8)
        s.releaseStale(at: s.lastLifeUp + 200)
        #expect(s.sync()?.status == .idle)
    }
    var open = hooked()
    open.hook("waiting"); _ = open.sync()
    open.ring = Data("Do you want to proceed?\r\n ❯ 1. Yes\r\n   2. No, and tell Claude what to do differently\r\n".utf8)
    open.releaseStale(at: open.lastLifeUp + 200)
    #expect(open.sync() == nil && open.record.status == .waiting)
}

/// Claude Code says it sits at its prompt only after a finished turn: a row that still works or asks missed a Stop. One held
/// for its subagents isn't that.
@Test func anAgentAtItsPromptIsDone() async throws {
    let w = try await world(); defer { w.d.stop() }
    let workspace = try await firstWorkspace(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(workspace.id), "command": "sleep 30"]), as: Session.self)
    let idle: JSONValue = .obj(["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
    func status() -> AgentStatus? { w.d.sessions.existing(s.id)?.snapshot.status }
    _ = try await w.c.call(SessionHook(id: s.id, event: "working"))
    _ = try await w.c.call(SessionHook(id: s.id, event: "done", backgroundTasks: [.obj(["type": "subagent"])]))
    _ = try await w.c.call(SessionHook(id: s.id, event: "waiting", notification: idle))
    #expect(status() == .working)
    _ = try await w.c.call(SessionHook(id: s.id, event: "working"))
    _ = try await w.c.call(SessionHook(id: s.id, event: "waiting", notification: idle))
    #expect(try await waitFor { status() == .done })
}

/// AskUserQuestion can ask several things: a key answers one, the form stays, and only its PostToolUse says it's through.
@Test func aKeyDoesntEndAQuestionWithMoreToAsk() {
    var s = hooked()
    s.hook("working"); s.hook("waiting", question: true); _ = s.sync()
    let through = s.answeredOne()
    #expect(!through)
    s.hook("working")
    let nothingLeft = s.answeredOne()
    #expect(nothingLeft && s.sync()?.status == .working)
}

/// A turn's summary, written a moment after it ended, isn't laid over the question the agent has gone on to ask.
@Test func aSummaryOfATurnLeavesAQuestionAlone() async throws {
    let w = try await world(); defer { w.d.stop() }
    let workspace = try await firstWorkspace(w)
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(workspace.id), "command": "sleep 30"]), as: Session.self)
    func summary() -> String? { w.d.sessions.existing(s.id)?.snapshot.summary }
    _ = try await w.c.call(SessionHook(id: s.id, event: "done"))
    _ = try await w.c.call(SessionAnnotate(id: s.id, summary: "Added the test", ifStatus: "done"))
    #expect(summary() == "Added the test")
    _ = try await w.c.call(SessionHook(id: s.id, event: "working"))
    _ = try await w.c.call(SessionHook(id: s.id, event: "waiting", notification: .obj(["message": "Allow rm?"])))
    _ = try await w.c.call(SessionAnnotate(id: s.id, summary: "Added the test", ifStatus: "done"))
    #expect(summary() == "Allow rm?")
}
