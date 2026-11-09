import Agents
import Core
import Foundation
import TestSupport
import Testing
import os

@testable import Daemon

private let readAndEcho = "echo before; while read l; do echo got-$l; done"

/// A session's state is a long list, and hand-overs lost a field more than once: a new one has to say here which it is.
@Test func everyFieldOfASessionGoesOverAnUpdateOrIsLetGoOnPurpose() {
    let s = LiveSession.State(
        record: Session(cwd: "/", command: "x"), manifest: AgentManifest(id: "x", name: "x", command: "x"),
        logSize: 0, callbacks: .init(), trail: .init(history: tmp(), session: "s"))
    let carried: Set = [
        "record", "detector", "ring", "ringModes", "logSize", "holding", "parked", "asking", "questionOpen", "turnEnd",
        "transcript",
        "boxEmpty", "pasteMode", "draftWaiting", "typing", "hooksSpoke", "pendingPrompts", "reports"
    ]
    let fromLaunch: Set = [
        "hooked", "selfNames", "trail", "started", "wantsTopic", "wantsURL", "wantsLimits", "autoAnswers"
    ]
    // Set by `adopted` as what's true of a program long past starting.
    let settled: Set = ["startedUp", "typedYet", "dialogSettled", "sawFirstPrompt"]
    // Of this connection or this moment, a carry of half a sequence, or only for a while: nothing is lost with it.
    let letGo: Set = [
        "attached", "lastOutputAt", "lastInputAt", "redrawUntil", "final", "letGo", "inputs", "inputsInFlight", "ended",
        "oscCarry", "titleCarry",
        "lastTopic", "utf8Carry", "pasteCarry", "sawURL", "sawBusy", "lastLimits", "limitSeen", "lastHookAt",
        "compactManual", "compactSummary",
        "lastLifeUp", "newestHook", "lineSentUp", "commands", "commandChanges", "interruptArmed", "goalAsked",
        "stopKeyAt",
        "steering", "updatedTo", "turnTree", "turnFolder", "turnResult", "turnStart", "inTurn", "lastSent",
        "turnPrompt",
        "retries",   // its `continueAt` is the record's: an update only starts the count of retries again
        "kelpQuestions"   // its commands' waits end with the daemon they waited on
    ]
    #expect(
        Set(Mirror(reflecting: s).children.compactMap(\.label)) == carried.union(fromLaunch).union(settled).union(letGo)
    )
}

/// An unread draft or a half-typed line stays in the box over an update, and a send's Enter mustn't take it along.
@Test func whatTextWouldLandOnGoesOverAnUpdate() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let from = try await c.call(SessionCreate(cwd: root.path, command: "cat")),
        to = try await c.call(SessionCreate(cwd: root.path, command: "cat"))
    let old = try #require(d.sessions.existing(from.id)), new = try #require(d.sessions.existing(to.id))
    old.state.withLock {
        $0.pasteMode = true
        $0.draftWaiting = true
        $0.typing = "half a li"
        $0.hooksSpoke = true
    }
    let handed = try JSONDecoder().decode(Handover.Session.self, from: JSONEncoder().encode(old.handedOver(fd: 0)))
    new.adopted(modes: handed.modes, bytes: 0, status: handed.status)
    let s = new.state.withLock {
        ($0.pasteMode, $0.draftWaiting, $0.typing, $0.hooksSpoke, $0.readyForText(submits: true))
    }
    #expect(s.0 && s.1 && s.2 == "half a li" && s.3 && !s.4)
    // A kelpd that didn't say leaves the modes it was in.
    let older = Handover.Status(
        holding: false, parked: true, hooked: false, asking: [:], questionOpen: false, turnEnd: TurnEnd(),
        transcript: nil)
    new.adopted(modes: "\u{1B}[?2004h", bytes: 0, status: older)
    #expect(new.state.withLock { $0.pasteMode })
}

/// An update hands each running session to the next kelpd (`handOver`, then `start(adopting:)`; kelpd execs in between):
/// the same program goes on, its history comes along, typing reaches it, and its end is still seen.
@Test func runningSessionsCarryOnIntoTheNextDaemon() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    // A daemon hosted in another program (this one) won't exec it.
    await #expect(throws: RPCError.self) { try await c.call(DaemonUpgrade()) }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    #expect(try await waitFor { d.sessions.existing(s.id)?.tail(4096).range(of: Data("before".utf8)) != nil })

    let next = try Daemon(root: root)
    try next.start(adopting: try #require(d.handOver()) as Handover)
    defer { next.stop() }
    #expect(d.sessions.existing(s.id) == nil)
    let c2 = try client(root)
    #expect(try await c2.call(DaemonInfo()).liveSessions == 1)
    #expect(kill(s.pid, 0) == 0 && next.sessions.existing(s.id)?.snapshot.pid == s.pid)
    #expect(try await c2.call(SessionRead(id: s.id)).contains("before"))
    _ = try await c2.call(SessionWrite(id: s.id, text: "x\n"))
    #expect(try await waitFor { try await c2.call(SessionRead(id: s.id)).contains("got-x") })
    _ = try await c2.call(SessionWrite(id: s.id, text: "\u{4}"))   // ⌃D: read ends, and so does the program
    #expect(try await waitFor { try await c2.call(SessionList()).first { $0.id == s.id }?.status == .exited })
}

/// An update refuses calls, then hangs up, while the agents go on: a hook sent then waits for the next kelpd. Lost, a Stop
/// left the row working for minutes. What's refused for another reason doesn't wait.
@Test func aHookOutlastsAnUpdate() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    let started = Date()
    await #expect(throws: RPCError.self) { try await SessionHook(id: s.id, event: nil).send(socket: d.socketPath) }
    #expect(Date().timeIntervalSince(started) < 1)

    d.offloads.close()   // how an update starts
    await #expect(throws: RPCError.updating) { try await c.call(SessionHook(id: s.id, event: "waiting")) }
    let refused = d.offloads.refusals
    let sent = Task { try await SessionHook(id: s.id, event: "waiting").send(socket: d.socketPath) }
    #expect(try await waitFor { d.offloads.refusals > refused })   // it tried, and was refused
    #expect(d.sessions.existing(s.id)?.snapshot.status != .waiting)

    let next = try Daemon(root: root)
    try next.start(adopting: try #require(d.handOver()) as Handover)
    defer { next.stop() }
    try await sent.value
    #expect(next.sessions.existing(s.id)?.snapshot.status == .waiting)
}

/// A kelpd that doesn't answer isn't waited for: the hook stays in the socket and is read when it's back, and the agent goes
/// on. Its next one can then be read first, and the older one says nothing about now.
@Test func aHookDoesntHoldItsAgentAndALateOneChangesNothing() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    let quiet = socket(AF_UNIX, SOCK_STREAM, 0), path = tmp().path.prefix(40) + ".s"
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { b in path.utf8.enumerated().map { b[$0] = $1 } }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(quiet, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bound == 0 && listen(quiet, 8) == 0)   // nobody accepts: a stopped kelpd
    defer {
        close(quiet)
        unlink(String(path))
    }
    try await SessionHook(id: s.id, event: "done").send(socket: String(path))
    // Sent once, unanswered: its wait for the reply is all the agent spends. Sent again, it would wait that long again,
    // until `within` ran out, and every try would be in the queue.
    _ = fcntl(quiet, F_SETFL, O_NONBLOCK)
    var queued: [Int32] = []
    while case let fd = accept(quiet, nil, nil), fd >= 0 { queued.append(fd) }
    queued.forEach { close($0) }
    #expect(queued.count == 1)

    _ = try await c.call(SessionHook(id: s.id, event: "working", at: 20))
    _ = try await c.call(SessionHook(id: s.id, event: "done", at: 30))
    #expect(try await waitFor { d.sessions.existing(s.id)?.snapshot.status == .done })
    _ = try await c.call(SessionHook(id: s.id, event: "waiting", at: 25))
    _ = try await c.call(SessionHook(id: s.id, event: "command", hookName: "PreToolUse", at: 26))
    #expect(d.sessions.existing(s.id)?.snapshot.status == .done)
    _ = try await c.call(SessionHook(id: s.id, event: "working"))   // no time: a caller that doesn't send one
    #expect(d.sessions.existing(s.id)?.snapshot.status == .working)

    // AskUserQuestion's end runs two hooks side by side: the tool's coming first doesn't drop the one that says the status.
    _ = try await c.call(SessionHook(id: s.id, event: "waiting", hookName: "PreToolUse", at: 40))
    _ = try await c.call(SessionHook(id: s.id, event: "command", hookName: "PostToolUse", at: 41.002))
    _ = try await c.call(SessionHook(id: s.id, event: "working", hookName: "PostToolUse", at: 41.001))
    #expect(d.sessions.existing(s.id)?.snapshot.status == .working)
}

/// What a status rests on goes along. A Stop held for its subagents stays held (it read as done 3 minutes later), a dialog
/// answered elsewhere still clears when its tools ran, and what an agent reported itself isn't guessed at again.
@Test func whatAStatusRestsOnGoesThroughAnUpdate() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let held = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    let asking = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    let reporting = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    let subagent: JSONValue = .obj(["type": "subagent", "status": "running"])
    _ = try await c.call(SessionHook(id: held.id, event: "working", transcript: "/p/\(held.id).jsonl"))
    _ = try await c.call(SessionHook(id: held.id, event: "done", backgroundTasks: [subagent]))
    _ = try await c.call(SessionHook(id: asking.id, event: "waiting", hookName: "PermissionRequest"))
    _ = try await c.call(SessionReport(id: reporting.id, state: "blocked"))
    #expect(try await waitFor { d.sessions.existing(reporting.id)?.snapshot.status == .waiting })

    let next = try Daemon(root: root)
    try next.start(adopting: try #require(d.handOver()) as Handover)
    defer { next.stop() }
    func live(_ s: Session) throws -> LiveSession { try #require(next.sessions.existing(s.id)) }
    #expect(try live(held).snapshot.status == .working && live(held).state.withLock { $0.holding })
    #expect(try live(held).transcriptPath == "/p/\(held.id).jsonl")
    #expect(try live(reporting).snapshot.status == .waiting)   // no OSC 7501 on its screen: `kelp report` said so
    let c2 = try client(root)
    _ = try await c2.call(SessionHook(id: asking.id, event: "command", hookName: "PostToolBatch"))
    #expect(try await waitFor { try live(asking).snapshot.status == .working })
}

/// A terminal made as the upgrade began, before anything read from it, is handed over too: its program isn't left to
/// a hang-up.
@Test func aTerminalNotStartedYetIsHandedOver() async throws {
    let p = try PTY(argv: ["/bin/sh", "-c", "echo ready; cat"], cwd: "/tmp", env: [:])
    let fd = try #require(p.handOver())
    let next = PTY(adopting: p.pid, fd: fd)
    let seen = OSAllocatedUnfairLock(initialState: false)
    next.onOutput = { d in if String(decoding: d, as: UTF8.self).contains("ready") { seen.withLock { $0 = true } } }
    next.start()
    defer { _ = next.terminate() }
    #expect(try await waitFor { seen.withLock { $0 } })
}

/// A question the kelpd before read off the screen is read again by the next one: Grok's opt-in banner, which the old
/// "allow .* to" took for one, doesn't keep it in Needs You after the update that fixed that. Read stays read.
@Test func aQuestionGuessedBeforeAnUpdateIsGuessedAgain() async throws {
    let screen =
        "Worked for 4m0s\nHelp improve Grok [Opt out] [Opt in]\nOff by default. Opt-in to allow SpaceXAI to retain coding data, "
        + "e.g., prompts, traces, & metrics, for training and debugging purposes. Change anytime via settings.\n"
    let grok = AgentManifest(id: "grok", name: "Grok", command: "/bin/sh", args: ["-c", "printf '\(screen)'; cat"])
    let (d, c, root) = try daemon(agents: [grok])
    defer { d.stop() }
    let s = try await c.call(SessionCreate(cwd: root.path, agent: "grok"))
    #expect(try await waitFor { d.sessions.existing(s.id)?.tail(4096).range(of: Data("SpaceXAI".utf8)) != nil })
    _ = try await c.call(SessionAnnotate(id: s.id, status: "waiting"))   // what the old kelpd made of it
    _ = try await c.call(SessionMarkRead(id: s.id))

    let next = try Daemon(root: root)
    try next.start(adopting: try #require(d.handOver()) as Handover)
    defer { next.stop() }
    let c2 = try client(root)
    #expect(try await waitFor { try await c2.call(SessionList()).first { $0.id == s.id }?.status == .done })
    #expect(try await c2.call(SessionList()).first { $0.id == s.id }?.unread == false)
}

/// kelpd itself: `daemon.upgrade` runs the binary at its path again in the same process, and the session's program never
/// stops.
@Test func kelpdUpgradesInPlace() async throws {
    let kelp = try #require(ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"])
    let root = tmp()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: kelp).deletingLastPathComponent().appendingPathComponent("kelpd")
    p.environment = ProcessInfo.processInfo.environment.merging(["KELP_HOME": root.path]) { $1 }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice   // left running, it would hold swift test open
    try p.run()
    defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }   // only the kelpd this test started; exec'd, it ignores SIGTERM at first
    func connected() async throws -> RPCClient? {
        var c: RPCClient?
        try await waitFor(5) {
            c = try? client(root)
            return c != nil
        }
        return c
    }
    let c = try #require(try await connected())
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    #expect(try await waitFor { try await c.call(SessionRead(id: s.id)).contains("before") })

    // A program the old run started that isn't a session (a git, a language server) ends after the exec: reaped, not a zombie.
    let stray = Task { try? await c.call(ProcessRun(argv: ["/bin/sleep", "1"])) }
    #expect(try await waitFor { children(of: p.processIdentifier).contains { name($0) == "sleep" } })
    _ = try await c.call(DaemonUpgrade())
    #expect(try await waitFor { (try? await c.call(Ping())) == nil })   // this connection ended with the old run
    _ = await stray.value
    let c2 = try #require(try await connected())
    let info = try await c2.call(DaemonInfo())
    #expect(info.pid == Int(p.processIdentifier) && info.liveSessions == 1 && p.isRunning)
    #expect(kill(s.pid, 0) == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("handover.json").path))
    _ = try await c2.call(SessionWrite(id: s.id, text: "x\n"))
    #expect(try await waitFor { try await c2.call(SessionRead(id: s.id)).contains("got-x") })
    #expect(
        try await waitFor(5) {
            children(of: p.processIdentifier).allSatisfy { name($0) != "sleep" && !Subprocess.isZombie($0) }
        })
    _ = try await c2.call(DaemonShutdown())
    #expect(try await waitFor { !p.isRunning && kill(s.pid, 0) != 0 })
}

/// `pid`'s children, zombies included.
private func children(of pid: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 256)
    let n = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    return Array(pids.prefix(max(0, n)))
}

/// Its program's name while it runs ("" once it has ended).
private func name(_ pid: pid_t) -> String {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return "" }
    return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// An update is refused before any session is given up when the new kelpd wouldn't take them (it says so itself:
/// `--can-adopt`), and stays refused for that binary, so the app asks instead of trying again.
@Test func anUpdateTheNewKelpdCantTakeIsRefusedFirst() throws {
    let kelp = try #require(ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"])
    let real = URL(fileURLWithPath: kelp).deletingLastPathComponent().appendingPathComponent("kelpd").path
    let home = tmp(), fake = home.appendingPathComponent("kelpd").path
    #expect(Handover.adoptable(real, home: home))
    try "#!/bin/sh\necho something else\n".write(toFile: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
    #expect(!Handover.adoptable(fake, home: home))
    let upgrade = Upgrade(executable: fake, root: home) {}
    #expect(upgrade.refused() == nil)
    Upgrade.refuse(root: home, executable: fake, "can't take them")
    #expect(upgrade.refused() == "can't take them")
    #expect(throws: RPCError.self) { try DaemonUpgrade().handle(upgrade) }
    // Refused in the call itself, before anything is handed over, so the app hears it as the call's error.
    let other = home.appendingPathComponent("again"),
        fresh = Upgrade(executable: fake, root: other, adoptable: { false }) {}
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    #expect(throws: RPCError.self) { try DaemonUpgrade().handle(fresh) }
    #expect(fresh.refused() != nil)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fake)   // replaced
    #expect(upgrade.refused() == nil)
}

/// An update whose exec fails (the binary went away, a signature the system refuses) doesn't end the agents: this
/// process takes the sessions back, as the new kelpd would have, and they go on answering.
@Test func anUpdateWhoseExecFailsKeepsTheSessions() async throws {
    let kelp = try #require(ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"])
    let kelpd = URL(fileURLWithPath: kelp).deletingLastPathComponent().appendingPathComponent("kelpd").path
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    #expect(try await waitFor { d.sessions.existing(s.id)?.tail(4096).range(of: Data("before".utf8)) != nil })
    let back = try #require(d.upgrade(to: kelpd) { _, _, _ in throw POSIXError(.ENOEXEC) })
    #expect(d.sessions.existing(s.id) == nil && back.sessions.existing(s.id)?.snapshot.pid == s.pid)
    #expect(back.store === d.store)   // one database writer in the process, not two
    let c2 = try client(root)
    _ = try await c2.call(SessionWrite(id: s.id, text: "y\n"))
    #expect(try await waitFor { try await c2.call(SessionRead(id: s.id)).contains("got-y") })
}

/// A send right before an update reaches the program whole, its Enter included (it comes 0.3 s behind the text): the
/// hand-over waits for what was sent, as the next kelpd couldn't send it.
@Test func aSendJustBeforeAnUpdateArrivesWithItsEnter() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    #expect(try await waitFor { d.sessions.existing(s.id)?.tail(4096).range(of: Data("before".utf8)) != nil })
    #expect(try await waitFor(30) { d.sessions.existing(s.id)?.startedUp == true })   // a send goes straight in
    _ = try await c.call(SessionSend(id: s.id, text: "whole"))
    let next = try Daemon(root: root)
    try next.start(adopting: try #require(d.handOver()) as Handover)
    defer { next.stop() }
    let c2 = try client(root)
    #expect(try await waitFor { try await c2.call(SessionRead(id: s.id)).contains("got-whole") })
}

/// Text sent before the agent is ready (it waits for it to start up) is typed by the kelpd that takes over, not lost.
@Test func aPromptWaitingForTheAgentIsTypedAfterAnUpdate() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    _ = try await c.call(SessionSend(id: s.id, text: "waited"))   // right away: it isn't started up yet, so it waits
    let next = try Daemon(root: root)
    try next.start(adopting: try #require(d.handOver()) as Handover)
    defer { next.stop() }
    let c2 = try client(root)
    #expect(try await waitFor(10) { try await c2.call(SessionRead(id: s.id)).contains("got-waited") })
}

/// Once a hand-over drains a session's input, no more is taken: a write is refused, not answered as done and lost.
@Test func inputAfterTheHandOverDrainIsRefused() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let s = try await c.call(SessionCreate(cwd: root.path, command: readAndEcho))
    let ls = try #require(d.sessions.existing(s.id))
    ls.drainInput(within: 1)
    #expect(ls.input { 1 } == nil)
}
