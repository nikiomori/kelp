import Foundation
import os
import Core
import Agents
import Testing
@testable import Daemon

@Test func ptyKillReportsExit() async throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "echo ready; cat"], cwd: "/tmp", env: [:])   // not a login shell: no profile of the user's runs
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.onExit = { box.exit($0) }
    p.start()
    #expect(try await waitFor(10) { box.text.contains("ready") })
    p.kill()
    #expect(try await waitFor(10) { box.code != nil })
}
final class Box: @unchecked Sendable {
    let l = NSLock(); var t = ""; var c: Int32?
    func add(_ s: String) { l.lock(); t += s; l.unlock() }
    func exit(_ x: Int32) { l.lock(); c = x; l.unlock() }
    var text: String { l.lock(); defer { l.unlock() }; return t }
    var code: Int32? { l.lock(); defer { l.unlock() }; return c }
}

/// Text in a session is UTF-8 even when the daemon has no locale (launchd starts it without one): pbcopy reads it that way.
@Test func aSessionGetsAUTF8LocaleWhenTheDaemonHasNone() {
    #expect(PTY.environment(["HOME": "/u"], [:])["LANG"] == "en_US.UTF-8")
    #expect(PTY.environment(["LANG": "ru_RU.UTF-8"], [:])["LANG"] == "ru_RU.UTF-8")   // the user's own stays
    #expect(PTY.environment(["LC_ALL": "C"], [:])["LANG"] == nil)
    #expect(PTY.environment([:], ["LC_CTYPE": "UTF-8"])["LANG"] == nil)
}

/// Agents must own the PTY as controlling terminal, or resizes (SIGWINCH) never reach them.
@Test func resizeReachesChild() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelp = root.appendingPathComponent(".build/debug/kelp").path
    try #require(FileManager.default.isExecutableFile(atPath: kelp), "build the kelp CLI first: swift build")
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "trap 'stty size; exit' WINCH; echo ready tty=$(ps -o tty= -p $$) size=$(stty size); while :; do sleep 0.1; done"],
                    cwd: "/tmp", env: [:], cols: 100, rows: 30, trampoline: kelp)
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.start()
    // Wait for the child rather than a fixed time: a busy machine (parallel builds) starts it late.
    for _ in 0..<50 where !box.text.contains("ready") { try await Task.sleep(for: .milliseconds(100)) }
    #expect(box.text.contains("ready"))
    #expect(!box.text.contains("tty=??"), "no controlling terminal: \(box.text.debugDescription)")
    #expect(box.text.contains("size=30 100"), "initial size lost: \(box.text.debugDescription)")
    p.resize(cols: 50, rows: 20)
    for _ in 0..<100 where !box.text.contains("20 50") { try await Task.sleep(for: .milliseconds(50)) }   // a busy machine is slow, not wrong
    #expect(box.text.contains("20 50"), "\(box.text.debugDescription)")
    p.kill()
}

/// A paused agent woken by a terminal the app hasn't laid out yet wakes at that terminal's first size; the real one,
/// sent while it woke, went nowhere (aResizeNeverWakesAPausedAgent). It still reaches the agent once it runs, or the
/// agent draws for a smaller screen than the one it's shown on, and its redraws leave the rest of the old screen behind.
@Test func theSizeATerminalGotWhileItsAgentWokeReachesTheAgent() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelp = root.appendingPathComponent(".build/debug/kelp").path
    try #require(FileManager.default.isExecutableFile(atPath: kelp), "build the kelp CLI first: swift build")
    let sizer = AgentManifest(id: "sizer", name: "Sizer", command: "/bin/sh",
                              args: ["-c", "trap 'echo SIZE=$(stty size)' WINCH; echo SIZE=$(stty size); while :; do sleep 0.1; done", "x"],
                              resumeArgs: ["--resume"])
    let w = try await world(agents: [sizer]); defer { w.d.stop() }
    let wt = try await desk(w, "sizes")
    let s: Session = try await w.c.call("session.create", .obj(["worktreeId": .string(wt.id), "agent": "sizer"]), as: Session.self)
    _ = try await w.c.call("worktree.archive", .obj(["id": .string(wt.id)]))
    _ = try await w.c.call("worktree.unarchive", .obj(["id": .string(wt.id)]))
    #expect(w.d.sessions.existing(s.id) == nil)
    // Its wake waits here while the terminal gets its real size.
    let held = Box(), release = DispatchSemaphore(value: 0)
    Thread.detachNewThread { w.d.sessions.wakeLocks.withLock(s.id) { held.add("held"); release.wait() } }
    #expect(try await waitFor(5) { held.text == "held" })
    let term = try PTY(argv: [kelp, "attach", s.id], cwd: "/tmp", env: ["KELP_SOCKET": w.root.appendingPathComponent("kelp.sock").path],
                       cols: 47, rows: 16, trampoline: kelp)
    let box = Box()
    term.onOutput = { box.add(String(decoding: $0, as: UTF8.self)) }
    term.start()
    defer { term.kill() }
    #expect(try await waitFor(10) { box.text.contains("\u{1B}[3J") })   // it asked for the session (it clears the screen next)
    term.resize(cols: 100, rows: 30)
    try await Task.sleep(for: .milliseconds(500))   // that size reached the daemon, with the session not running yet
    release.signal()
    #expect(try await waitFor(10) { box.text.contains("SIZE=30 100") }, "\(box.text.debugDescription)")
}

/// Agents are found on the login-shell PATH even when the daemon itself started with a bare one (from Finder).
@Test func loginPathFindsToolsAndExplainsMisses() throws {
    #expect(try LoginPath.resolve("git").hasSuffix("/git"))
    #expect(throws: RPCError.self) { try LoginPath.resolve("kelp-no-such-agent-cli") }
}

/// The limits probe drops its PTY right after signalling the agent, which still writes as it quits. As the terminal's
/// controlling process it then waits in exit for that output to be read, and nobody read it any more: it hung there
/// for good, each one holding a PTY until the daemon ran out of file descriptors.
@Test func droppedPTYLetsItsProgramExit() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelp = root.appendingPathComponent(".build/debug/kelp").path
    try #require(FileManager.default.isExecutableFile(atPath: kelp), "build the kelp CLI first: swift build")
    let pid: pid_t
    do {
        let box = Box()
        let p = try PTY(argv: ["/bin/sh", "-c", "trap 'echo bye; exit 0' TERM HUP; echo ready; while :; do sleep 0.1; done"],
                        cwd: "/tmp", env: [:], trampoline: kelp)
        p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
        p.start()
        for _ in 0..<50 where !box.text.contains("ready") { try await Task.sleep(for: .milliseconds(100)) }
        pid = p.pid
        p.terminate()
    }
    for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(kill(pid, 0) != 0, "still there: stuck exiting on a terminal nobody reads")
}

/// Once its program has exited a PTY's fd (and pid) may be someone else's: typing into it reaches nobody.
@Test func endedPTYWritesNowhere() async throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "exit 0"], cwd: "/tmp", env: [:])
    p.onExit = { box.exit($0) }
    p.start()
    for _ in 0..<50 where box.code == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(box.code != nil)
    // The freed fd number goes to whatever opens next: socket pairs, so anything written to one end shows at the other.
    var pairs: [[Int32]] = []
    for _ in 0..<16 { var sv: [Int32] = [0, 0]; _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &sv); pairs.append(sv) }
    defer { pairs.joined().forEach { close($0) } }
    p.write(Data("typed-after-exit".utf8)); p.resize(cols: 10, rows: 10); p.kill()
    #expect(p.foregroundProgram == nil)
    var got = 0
    for fd in pairs.joined() {
        var b = [UInt8](repeating: 0, count: 64)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        if read(fd, &b, b.count) > 0 { got += 1 }
    }
    #expect(got == 0)
}

/// A shell running `sleep` is busy with it; at its prompt it is not (closing it would stop that program).
@Test func aShellRunningAProgramReportsItAsForeground() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelp = root.appendingPathComponent(".build/debug/kelp").path
    try #require(FileManager.default.isExecutableFile(atPath: kelp), "build the kelp CLI first: swift build")
    let box = Box()
    let p = try PTY(argv: ["/bin/zsh", "-f", "-i"], cwd: "/tmp", env: [:], trampoline: kelp)   // job control needs the controlling terminal
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.start()
    defer { p.kill() }
    #expect(try await waitFor(10) { box.text.contains("%") })   // its prompt is drawn
    #expect(p.foregroundProgram == nil)   // at the prompt
    p.write(Data("sleep 30\n".utf8))
    var seen: String?
    // Until it is sleep: just after the fork the foreground is briefly a copy of the shell, not yet the program.
    for _ in 0..<200 where seen != "sleep" { try await Task.sleep(for: .milliseconds(100)); seen = p.foregroundProgram }   // up to 20 s on a loaded machine
    #expect(seen == "sleep")
}

@Test func aTerminalThatCantBeOpenedYetIsRetriedButOtherErrorsAreNot() throws {
    var calls = 0
    let ok = try PTY.retrying { () throws -> String in
        calls += 1
        if calls < 3 { throw PTYError(step: "spawn", code: EIO) }
        return "started"
    }
    #expect(ok == "started" && calls == 3)   // two refusals, then it worked
    calls = 0
    #expect(throws: PTYError.self) { try PTY.retrying { () throws -> Int in calls += 1; throw PTYError(step: "spawn", code: ENOENT) } }
    #expect(calls == 1)                      // a missing program won't appear by trying again
    calls = 0
    _ = try PTY.retrying { () throws -> Int in calls += 1; if calls < 2 { throw PTYError(step: "openpty", code: ENXIO) }; return 1 }
    #expect(calls == 2)                      // openpty's own transient refusal is retried too
    calls = 0
    #expect(throws: PTYError.self) { try PTY.retrying(attempts: 3) { () throws -> Int in calls += 1; throw PTYError(step: "spawn", code: EIO) } }
    #expect(calls == 3)                      // and it gives up in the end, with the real error
}

@Test func theErrorSaysWhichStepFailed() {
    let e = PTYError(step: "openpty", code: EMFILE)
    #expect(e.description.contains("openpty") && e.description.contains("errno \(EMFILE)"))
    #expect(e.localizedDescription == e.description)   // what the app shows, not "The operation couldn't be completed"
}

@Test func theProgramBeingStartedThatDoesntExistFailsWithAClearError() {
    #expect(throws: PTYError.self) { _ = try PTY(argv: ["/definitely/not/a/program"], cwd: "/tmp", env: [:], trampoline: nil) }
}

/// `daemon.shutdown` ends the process, so it is tried on a real `kelpd` of its own.
@Test func shutdownStopsTheDaemonProcessAndRemovesItsSocket() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let kelpd = root.appendingPathComponent(".build/debug/kelpd").path
    try #require(FileManager.default.isExecutableFile(atPath: kelpd), "build kelpd first: swift build")
    let home = tmp()
    let p = Process(); p.executableURL = URL(fileURLWithPath: kelpd)
    var env = ProcessInfo.processInfo.environment; env["KELP_HOME"] = home.path; p.environment = env
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run()
    defer { if p.isRunning { p.terminate() } }   // only the daemon this test started
    let sock = home.appendingPathComponent("kelp.sock").path
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: sock) })
    let c = try RPCClient(socket: sock)
    #expect(try await c.call("ping").string == "pong")
    _ = try await c.call("daemon.shutdown")
    #expect(try await waitFor(10) { !p.isRunning })
    #expect(p.terminationStatus == 0)   // a clean exit, not a crash
}

/// A paste into a program that isn't reading (a build in the foreground) holds up nothing: not the caller (a connection's
/// reader thread), not the questions the app asks about the terminal.
@Test func writingToAProgramThatIsntReadingBlocksNothing() throws {
    let box = Box()
    let p = try PTY(argv: ["/bin/sh", "-c", "stty raw -echo; echo ready; sleep 30"], cwd: "/tmp", env: [:])   // raw, like a TUI: input queues up
    p.onOutput = { box.add(String(bytes: $0, encoding: .utf8) ?? "") }
    p.start()
    defer { p.kill() }
    for _ in 0..<100 where !box.text.contains("ready") { usleep(20_000) }
    let big = Data(repeating: 0x61, count: 2 << 20)   // far more than the terminal buffers
    let t = Date()
    p.write(big)
    #expect(Date().timeIntervalSince(t) < 1)         // queued, not written here (written here it would block for good)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { p.resize(cols: 100, rows: 30); _ = p.foregroundProgram; done.signal() }   // its own thread: a busy pool mustn't look like a stuck lock
    #expect(done.wait(timeout: .now() + 2) == .success, "resize / foregroundProgram waited on the stuck write")
}

/// A terminal closes its fds once: finishing and being dropped both hang up, and a second close would hit whatever
/// reuses the number by then. Here a pipe takes each freed number before the drop, and must survive it.
@Test func aFinishedTerminalClosesItsFdsOnce() async throws {
    var held = 0
    for _ in 0..<60 where held < 6 {   // until some freed numbers were had (tests running alongside take them too)
        var p: PTY? = try PTY(argv: ["/bin/sh", "-c", "exit 0"], cwd: "/tmp", env: [:])
        let ended = Box()
        p?.onExit = { ended.exit($0) }
        p?.start()
        #expect(try await waitFor(5) { ended.code != nil })
        let fds = [p?.primaryFD ?? -1, p?.writeFD ?? -1], writes = p?.writes   // no other reference: the drop below is the last
        writes?.sync {}   // finished: its first close of the write end has run (the terminal's own goes on its read queue)
        // Each freed number, taken again: by the pipe itself (the lowest free numbers), else a copy of it. Only a number that
        // is free now (closed by the terminal already, not taken by another test meanwhile) can be had either way.
        let pipe = Pipe(), ends = [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor]
        let holders = fds.compactMap { fd -> Int32? in
            if ends.contains(fd) { return fd }
            let h = fcntl(ends[0], F_DUPFD, fd)
            if h == fd { return h }
            if h >= 0 { close(h) }
            return nil
        }
        held += holders.count
        p = nil   // dropped: deinit hangs up again, and must close nothing
        writes?.sync {}   // a close it queued has run
        #expect(holders.allSatisfy { fcntl($0, F_GETFD) != -1 }, "closed under us")
        holders.filter { !ends.contains($0) }.forEach { close($0) }
        withExtendedLifetime(pipe) {}
    }
    #expect(held > 0)
}

/// Tests start programs as kelpd does, through `kelp __ctty`: the terminal is the program's controlling terminal, so a
/// program that never touches it (`yes > /dev/null`) still gets the hangup when its daemon's process dies without
/// stopping it. Without it, every test process that crashed or was killed left such programs running for good.
@Test func aProgramThatNeverTouchesItsTerminalStillGetsTheHangup() async throws {
    #expect(PTY.trampoline != nil)
    var pty: PTY? = try PTY(argv: ["/bin/zsh", "-c", "echo up; exec yes > /dev/null"], cwd: "/tmp", env: [:])
    let pid = try #require(pty?.pid)
    let out = OSAllocatedUnfairLock(initialState: "")
    pty?.onOutput = { d in out.withLock { $0 += String(decoding: d, as: UTF8.self) } }
    pty?.start()
    #expect(try await waitFor(5) { out.withLock { $0 }.contains("up") })
    pty = nil   // dropped: its end of the terminal closes, as when the daemon's process ends
    let gone = try await waitFor(5) { kill(pid, 0) != 0 }
    if !gone { kill(pid, SIGKILL) }
    #expect(gone)
}
