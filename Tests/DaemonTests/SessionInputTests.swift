import Foundation
import os
import Testing
import Core
import Agents
@testable import Daemon

/// A send to a paused agent that can't wake says so: the reply waits for the wake. It used to answer OK at once and log
/// the failure, so `kelp send` and the app showed nothing.
@Test func aSendWhoseWakeFailsSaysSo() async throws {
    let w = try await world(agents: [AgentManifest(id: "gone", name: "Gone", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "wake-fails")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "gone"))
    try await hibernate(after: 0.03, w.c)   // ~2 s
    #expect(try await waitFor(15) { try await w.c.call(SessionList()).first { $0.id == s.id }?.status == .hibernated })
    try await hibernate(after: 0, w.c)
    try FileManager.default.removeItem(at: w.root.appendingPathComponent("agents/gone.json"))   // nothing to wake it with
    await #expect(throws: RPCError.self) { _ = try await w.c.call(SessionSend(id: s.id, text: "hello")) }
}

/// A send with its Return never lands on a line the user is half-way through typing: it would send their line with it.
/// It's refused until they send or clear it; text that isn't sent (a reference) still goes in beside theirs.
@Test func aSendDoesntSendTheUsersHalfWrittenLine() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "half")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "stty -echo; echo ready; exec cat"))
    func screen() async throws -> String { try await w.c.call(SessionRead(id: s.id)) }
    func keys(_ k: String) async throws { _ = try await w.c.call(SessionWrite(id: s.id, base64: Data(k.utf8).base64EncodedString())) }
    #expect(try await waitFor(10) { try await screen().contains("ready") })
    #expect(try await waitFor(30) { w.d.sessions.existing(s.id)?.startedUp == true })   // sends go straight in
    try await keys("half")
    await #expect(throws: RPCError.self) { _ = try await w.c.call(SessionSend(id: s.id, text: "hello")) }
    _ = try await w.c.call(SessionSend(id: s.id, text: " ref", enter: false))
    try await keys("\u{15}")   // ⌃U: their line is gone (the terminal's kill character for cat, too)
    _ = try await w.c.call(SessionSend(id: s.id, text: "hello"))
    #expect(try await waitFor(10) { try await screen().contains("hello") })
    #expect(!(try await screen()).contains("half"))
}

/// Keys the user presses while a send waits for its Return (0.3 s, so the agent takes the text as typed) land after
/// that Return: they used to go in between, and the Return sent them with the prompt ("hellox").
@Test func keysPressedDuringASendComeAfterItsReturn() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "keys-after")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "stty -echo; echo ready; exec cat"))
    func screen() async throws -> String { try await w.c.call(SessionRead(id: s.id)) }
    #expect(try await waitFor(10) { try await screen().contains("ready") })
    #expect(try await waitFor(30) { w.d.sessions.existing(s.id)?.startedUp == true })   // the send is typed now
    _ = try await w.c.call(SessionSend(id: s.id, text: "hello"))
    _ = try await w.c.call(SessionWrite(id: s.id, base64: Data("x\r".utf8).base64EncodedString()))   // within its 0.3 s
    func lines() async throws -> [String] { try await screen().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } }
    #expect(try await waitFor(10) { try await lines().contains("x") })
    #expect(try await lines().suffix(2) == ["hello", "x"])
}

/// What the user typed and hasn't sent, followed from their keys.
@Test func theUsersUnsentLineIsFollowedFromTheirKeys() {
    var s = LiveSession.State(record: Session(cwd: "/", command: "cat"), manifest: AgentManifest(id: "custom", name: "Custom", command: "/bin/cat"),
                              logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "s"))
    func keys(_ k: String) -> String? { s.noteTyping(Data(k.utf8)) }
    _ = keys("fix the"); #expect(s.typing == "fix the")
    _ = keys("\u{7F}\u{7F}"); #expect(s.typing == "fix t")
    _ = keys("\u{17}"); #expect(s.typing == "fix ")   // ⌃W
    _ = keys("x\u{1B}\u{7F}"); _ = keys("\u{1B}\u{7F}"); #expect(s.typing.isEmpty)   // "x", then ⌥⌫ twice
    _ = keys("\u{1B}[A"); #expect(s.typing.isEmpty)   // an arrow
    _ = keys("\u{1B}[200~two\rlines\u{1B}[201~"); #expect(s.typing == "two\nlines")   // a paste's newlines don't send it
    _ = keys("\u{3}"); #expect(s.typing.isEmpty)   // ⌃C
    #expect(keys("fix the login bug\r") == "fix the login bug")   // sent: the first prompt, which names the session
    #expect(s.typing.isEmpty)
    #expect(keys("and the tests\r") == nil)
    // As the kitty keyboard protocol sends them (Claude Code turns it on): ⌃U, ⌥⌫ (not its release), ⇧Return, Return.
    _ = keys("half"); _ = keys("\u{1B}[117;5u"); #expect(s.typing.isEmpty)
    _ = keys("half"); _ = keys("\u{1B}[1075::117;5u"); #expect(s.typing.isEmpty)   // ⌃U on a Cyrillic layout
    _ = keys("ab cd"); _ = keys("\u{1B}[127;3u"); _ = keys("\u{1B}[127;3:3u"); #expect(s.typing == "ab ")
    _ = keys("\u{1B}[13;2u"); #expect(s.typing == "ab ")
    _ = keys("\u{1B}[13u"); #expect(s.typing.isEmpty)
}

/// Sessions that ended over a week ago go, records and logs, and logs nobody's record names; paused and newer ones stay.
@Test func endedSessionsGoAfterAWeek() throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let week = Sessions.keepEnded, history = root.appendingPathComponent("history"), fm = FileManager.default
    try fm.createDirectory(at: history, withIntermediateDirectories: true)
    let old = Session(cwd: "/tmp", command: "x", status: .exited, createdAt: Date() - week - 3600)
    var recent = Session(cwd: "/tmp", command: "x", status: .exited, createdAt: Date() - week - 3600); recent.statusAt = Date() - 3600
    let paused = Session(cwd: "/tmp", command: "x", status: .hibernated, createdAt: Date() - week * 4)
    for s in [old, recent, paused] { try d.store.save(s); try Data("out".utf8).write(to: history.appendingPathComponent("\(s.id).log")) }
    let trail = history.appendingPathComponent("\(old.id).trail")
    let orphan = history.appendingPathComponent("orphan.log"), orphanTrail = history.appendingPathComponent("orphan.trail")
    let fresh = history.appendingPathComponent("fresh.log")
    for f in [trail, orphan, orphanTrail, fresh] { try Data().write(to: f) }
    for f in [orphan, orphanTrail] { try fm.setAttributes([.modificationDate: Date() - 2 * 86400], ofItemAtPath: f.path) }
    d.sessions.pruneEnded()
    #expect(try d.store.sessions().map(\.id).sorted() == [recent.id, paused.id].sorted())
    #expect(!fm.fileExists(atPath: history.appendingPathComponent("\(old.id).log").path))
    #expect(fm.fileExists(atPath: history.appendingPathComponent("\(recent.id).log").path))
    #expect(!fm.fileExists(atPath: orphan.path) && !fm.fileExists(atPath: orphanTrail.path) && !fm.fileExists(atPath: trail.path))
    #expect(fm.fileExists(atPath: fresh.path))   // a session being created writes its log before its record
}

/// An agent asked for while the daemon stops isn't started: its pause has passed, so it would run on after the daemon
/// with nobody to pause it, and a wake later would start a second copy.
@Test func nothingStartsWhileTheDaemonStops() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await desk(w, "stopping")
    w.d.sessions.pauseAll()
    await #expect(throws: RPCError.self) { _ = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec sleep 30")) }
    #expect(try w.d.store.sessions().isEmpty)
    #expect(w.d.sessions.live.all.isEmpty)
}

/// A pause is the record's last word: a status change that read the record just before it, still on its way to the
/// database, isn't saved over it. It was, and the agent, gone, stayed "working" and could never be woken.
@Test func aPauseIsntWrittenOverByAnOlderStatus() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "pausing")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    let ls = try #require(w.d.sessions.live[s.id])
    let gate = DispatchSemaphore(value: 0)
    ls.inOrder { let old = ls.snapshot; gate.wait(); _ = try? w.d.store.update(old) }   // held until the pause had its say
    let paused = OSAllocatedUnfairLock(initialState: false)
    Thread.detachNewThread { try? w.d.sessions.pauseSessions(of: wt.id); paused.withLock { $0 = true } }
    #expect(try await waitFor(5) { w.d.sessions.live[s.id] == nil })   // the pause took it out; its save waits behind the gate
    gate.signal()
    #expect(try await waitFor(10) { paused.withLock { $0 } })
    await withCheckedContinuation { c in ls.inOrder { c.resume() } }   // whatever was queued is saved by now
    #expect(try w.d.store.session(s.id)?.status == .hibernated)
}

/// A paused agent woken at once says it's running: a status change of its old program that was queued before the pause
/// doesn't save the pause again over the wake. It did when that change was queued a second time behind the pause.
@Test func aWakeIsntWrittenOverByThePausedProgram() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "rewake")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    let old = try #require(w.d.sessions.live[s.id])
    let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
    old.inOrder { first.wait() }
    old.hook("working")   // its status change, queued behind `first`
    let paused = OSAllocatedUnfairLock(initialState: false)
    Thread.detachNewThread { try? w.d.sessions.pauseSessions(of: wt.id); paused.withLock { $0 = true } }
    #expect(try await waitFor(5) { w.d.sessions.live[s.id] == nil })   // the pause took it out; its own save is queued next
    old.inOrder { second.wait() }   // whatever the status change queues again lands behind this
    first.signal()
    #expect(try await waitFor(10) { paused.withLock { $0 } })
    let woken = try w.d.sessions.liveSession(s.id)
    await withCheckedContinuation { c in woken.inOrder { c.resume() } }
    second.signal()
    await withCheckedContinuation { c in old.inOrder { c.resume() } }
    #expect(try w.d.store.session(s.id)?.status != .hibernated)
}

/// Input that came after an idle pause looked keeps the agent running: the pause would stop the program it was just
/// given to, and the text, answered OK, would be gone.
@Test func anIdlePauseLeavesAnAgentThatJustGotInput() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "late-input")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    let ls = try #require(w.d.sessions.live[s.id])
    let seen = ls.inputs
    _ = try await w.c.call(SessionWrite(id: s.id, text: "hello\r"))
    w.d.sessions.pauseIdle(ls, inputs: seen)
    #expect(w.d.sessions.live[s.id] === ls)
}

/// Input that comes while an idle pause stops the program waits for it and wakes the agent: it used to be refused
/// ("no live session") because the pause hadn't been saved yet.
@Test func inputDuringAnIdlePauseWakesTheAgent() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "mid-pause")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    let ls = try #require(w.d.sessions.live[s.id])
    let gate = DispatchSemaphore(value: 0)
    ls.inOrder { gate.wait() }   // the pause's last save waits behind this: it's out of `live`, not yet saved as paused
    Thread.detachNewThread { w.d.sessions.pauseIdle(ls, inputs: ls.inputs) }
    #expect(try await waitFor(5) { w.d.sessions.live[s.id] == nil })
    let sent = Task { try await w.c.call(SessionWrite(id: s.id, text: "hello\r")) }
    #expect(try await waitFor(5) { !w.d.sessions.lanes.isClear(s.id) })   // the write waits on the session's lane
    gate.signal()
    _ = try await sent.value
    #expect(try #require(w.d.sessions.live[s.id]) !== ls)
}

/// An attach to a paused agent that can't wake says why once: it isn't tried a second time on the slow path.
@Test func anAttachWhoseWakeFailsTriesOnce() async throws {
    let w = try await world(agents: [AgentManifest(id: "gone2", name: "Gone", command: "/bin/zsh", args: ["-c", "echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "attach-fails")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "gone2"))
    try await hibernate(after: 0.03, w.c)
    #expect(try await waitFor(15) { try await w.c.call(SessionList()).first { $0.id == s.id }?.status == .hibernated })
    try await hibernate(after: 0, w.c)
    try FileManager.default.removeItem(at: w.root.appendingPathComponent("agents/gone2.json"))
    let before = w.d.sessions.wakeTries.withLock { $0 }
    await #expect(throws: RPCError.self) { _ = try await w.c.call(SessionAttach(id: s.id)) }
    #expect(w.d.sessions.wakeTries.withLock { $0 } - before == 1)
}

/// Whether a pause can bring a session back is known from its start: an agent that resumes can, a plain command can't.
@Test func aSessionKnowsFromItsStartWhetherAPauseCanBringItBack() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await desk(w, "resumable")
    let agent = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    let command = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "exec cat"))
    #expect(w.d.sessions.live[agent.id]?.resumable == true && w.d.sessions.live[command.id]?.resumable == false)
}

@Test func cutShortTurnsAreRecognisedOnScreen() {
    #expect(LiveSession.printedStopped("⎿ Interrupted · What should Claude do instead?"))
    #expect(LiveSession.printedStopped("■ Conversation   interrupted - tell the model\nwhat to do differently."))
    #expect(!LiveSession.printedStopped("Reading the interrupt handler in main.swift"))
}
