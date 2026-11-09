import Agents
import Core
import Foundation
import GitKit
import TestSupport
import Testing
import os

@testable import Daemon

/// A daemon on a fresh home, a client, and the first workspace of one project.
private func project() async throws -> (Daemon, RPCClient, Worktree, URL) {
    let p = try await world()
    return (p.d, p.c, try await firstWorkspace(p), p.root)
}

private func status(_ c: RPCClient, _ id: String) async throws -> AgentStatus? {
    try await c.call("session.list", as: [Session].self).first { $0.id == id }?.status
}

/// An ended session leaves the live set (its fd and pid are nobody's now) but its tab still shows what it printed,
/// and a hook that comes late neither wakes nor revives it.
@Test func endedSessionLeavesButKeepsItsScreen() async throws {
    let (d, c, w, _) = try await project()
    defer { d.stop() }
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "echo last-words"]), as: Session.self)
    #expect(try await waitFor { try await status(c, s.id) == .exited })
    #expect(try await waitFor { d.sessions.existing(s.id) == nil })
    let h = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    let screen = String(bytes: Data(base64Encoded: h["history"]?.string ?? "") ?? Data(), encoding: .utf8) ?? ""
    #expect(screen.contains("last-words"))
    _ = try await c.call("session.hook", .obj(["id": .string(s.id), "event": "working"]))
    #expect(try await status(c, s.id) == .exited)
}

/// Restart replaces the session: the old one's exit, which comes after, doesn't put its record (or log) back.
@Test func restartLeavesNoGhost() async throws {
    let (d, c, w, root) = try await project()
    defer { d.stop() }
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    let old = try #require(d.sessions.existing(s.id))
    let r: Session = try await c.call("session.restart", .obj(["id": .string(s.id)]), as: Session.self)
    #expect(try await waitFor(10) { kill(s.pid, 0) != 0 })   // the old program is gone
    // Its exit handled (the old session says exited) and everything that queued (a save, an event) done: then nothing
    // can come back later.
    #expect(try await waitFor(10) { old.snapshot.status == .exited })
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in old.inOrder { c.resume() } }
    let ids = try await c.call("session.list", as: [Session].self).map(\.id)
    #expect(ids.contains(r.id) && !ids.contains(s.id))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/\(s.id).log").path))
}

/// Removing a project stops its agents: none keeps working (and spending) out of sight.
@Test func removingAProjectEndsItsAgents() async throws {
    let (d, c, w, _) = try await project()
    defer { d.stop() }
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": "sleep 30"]), as: Session.self)
    _ = try await c.call("repo.remove", .obj(["id": .string(w.repoId)]))
    #expect(try await waitFor { kill(s.pid, 0) != 0 })
    #expect(try await c.call("session.list", as: [Session].self).allSatisfy { $0.id != s.id })
}

/// Numbers out of range (a typo on the CLI: `kelp terminal read <id> -1`) are clamped, not a crash that ends every agent.
@Test func outOfRangeNumbersAreClamped() async throws {
    let (d, c, w, _) = try await project()
    defer { d.stop() }
    d.agentUsage.agentHomes.withLock { $0 = (tmp(), tmp()) }
    let s: Session = try await c.call(
        "session.create",
        .obj(["worktreeId": .string(w.id), "command": "echo hi; sleep 30", "cols": -3, "rows": 70000]),
        as: Session.self)
    _ = try await c.call("session.read", .obj(["id": .string(s.id), "bytes": -1]))
    _ = try await c.call("session.context", .obj(["id": .string(s.id), "bytes": -1]))
    _ = try await c.call("session.resize", .obj(["id": .string(s.id), "cols": -5, "rows": 99999]))
    _ = try await c.call("history.list", .obj(["limit": -1]))
    await #expect(throws: RPCError.self) {
        try await c.call("ports.stop", .obj(["worktreeId": .string(w.id), "pid": .int(Int.max)]))
    }
    #expect(try await c.call("ping").string == "pong")
}

/// A second daemon for the same home (launchd's KeepAlive, a CLI that couldn't connect) bows out instead of taking the
/// socket and marking the first one's agents paused.
@Test func oneDaemonPerHome() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    #expect(throws: (any Error).self) { try Daemon(root: root).start() }
    #expect(try await c.call("ping").string == "pong")
}

/// `.kelp-remote` is Kelp's own marker in its own folder; one committed to a repository is just a file.
@Test func remoteMarkerCountsOnlyInKelpsFolder() throws {
    let root = tmp(), remotes = Remotes(home: root)
    let marker = try JSONEncoder().encode(RemoteHost(host: "evil.example", path: "/x"))
    let cloned = try makeRepo()
    try marker.write(to: URL(fileURLWithPath: cloned + "/" + RemoteHost.marker))
    #expect(remotes.of(cloned) == nil)
    let mine = root.appendingPathComponent("remote/box/app")
    try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    try marker.write(to: mine.appendingPathComponent(RemoteHost.marker))
    #expect(remotes.of(mine.path)?.host == "evil.example")
    try JSONEncoder().encode(RemoteHost(host: "-oProxyCommand=touch /tmp/x", path: "/x")).write(
        to: mine.appendingPathComponent(RemoteHost.marker))
    #expect(remotes.of(mine.path) == nil)
    #expect(Array(RemoteHost(host: "box", path: "/x").sshArgs(tty: false).suffix(2)) == ["--", "box"])
}

/// JSON-RPC ids may be strings; a line that isn't a request still gets an answer when it has an id.
@Test func stringIdsComeBackAsSent() async throws {
    let (d, _, root) = try daemon()
    defer { d.stop() }
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    Unix.writeAll(
        fd, Data((#"{"jsonrpc":"2.0","id":"a1","method":"ping"}"# + "\n" + #"{"jsonrpc":"2.0","id":7}"# + "\n").utf8))
    var lb = LineBuffer(), lines: [JSONValue] = [], buf = [UInt8](repeating: 0, count: 4096)
    while lines.count < 2 {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { break }
        lines += lb.append(Data(buf[0..<n])).compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
    #expect(lines.contains { $0["id"] == "a1" && $0["result"] == "pong" })
    #expect(lines.contains { $0["id"] == 7 && $0["error"]?["code"] == -32600 })
}

/// Big requests and replies on one connection, many at once: each line arrives whole (a Unix socket takes 8 KB at a
/// time, and a reply written in pieces used to get another one in between — both were dropped and the calls hung).
@Test func bigMessagesDontMixOnTheWire() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let big = JSONValue.obj(["blob": .string(String(repeating: "x", count: 300_000))])
    _ = try await c.call("ui.publish", .obj(["state": big]))
    try await withThrowingTaskGroup(of: Bool.self) { g in
        for i in 0..<40 {
            g.addTask {
                if i % 5 == 0 {
                    _ = try await c.call("ui.publish", .obj(["state": big]), timeout: 15)
                    return true
                }
                return try await c.call("ui.state", timeout: 15) == big
            }
        }
        for try await ok in g { #expect(ok) }
    }
}

/// `kelp attach` gets the history first and the live output after it, never a live chunk ahead of the history.
@Test func attachSendsHistoryBeforeLiveOutput() async throws {
    let (d, c, w, root) = try await project()
    defer { d.stop() }
    let count = "i=0; while [ $i -lt 300000 ]; do i=$((i+1)); echo n$i; done; sleep 30"
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": .string(count)]), as: Session.self)
    #expect(
        try await waitFor(10) {
            (try await c.call("session.read", .obj(["id": .string(s.id), "bytes": 100]))).string?.contains("n") == true
        })
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    Unix.writeAll(fd, try Wire.line(RPCRequest(id: nil, method: "session.stream", params: .obj(["id": .string(s.id)]))))
    var got = Data(), buf = [UInt8](repeating: 0, count: 65536)
    let end = Date().addingTimeInterval(1.5)
    while Date() < end {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        got.append(contentsOf: buf[0..<n])
    }
    let lines = (String(bytes: got, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).dropFirst().dropLast()   // the ends may be cut
    let numbers = lines.compactMap { Int($0.drop { !$0.isNumber }) }
    #expect(numbers.count > 100)
    #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $0 < $1 })
}

/// Modes a program set before the replayed megabyte still reach a new terminal: Codex's alternate screen and mouse
/// reporting (else the wheel scrolls the terminal, not Codex), in their order; synchronized output doesn't.
@Test func attachRestoresModesSetBeforeTheReplay() async throws {
    let (d, c, w, _) = try await project()
    defer { d.stop() }
    let modes =
        "printf '\\033[?1049h\\033[?1000;1006h\\033[?1007l\\033[?2026h'; head -c 3000000 /dev/zero | tr '\\0' x; echo; echo tail-mark; sleep 30"
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": .string(modes)]), as: Session.self)
    #expect(
        try await waitFor(30) {
            try await c.call("session.read", .obj(["id": .string(s.id), "bytes": 200])).string?.contains("tail-mark")
                == true
        })
    let h = try await c.call("session.attach", .obj(["id": .string(s.id)]))
    let history = String(bytes: Data(base64Encoded: h["history"]?.string ?? "") ?? Data(), encoding: .utf8) ?? ""
    let restored = history.prefix { $0 != "x" }
    #expect(restored.contains("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?1007l"))
    #expect(!restored.contains("2026"))
}

/// A session's log keeps what it printed across a pause (see hibernateAndWake) and stops growing at `logLimit`.
@Test func historyLogStaysBounded() async throws {
    let (d, c, w, root) = try await project()
    defer { d.stop() }
    let flood = "head -c 9000000 /dev/zero | tr '\\0' x; echo; echo tail-mark; sleep 30"
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": .string(flood)]), as: Session.self)
    #expect(
        try await waitFor(30) {
            try await c.call("session.read", .obj(["id": .string(s.id), "bytes": 200])).string?.contains("tail-mark")
                == true
        })
    let size =
        try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history/\(s.id).log").path)[.size]
        as? Int ?? 0
    #expect(size > 0 && size <= LiveSession.logLimit)
}

/// A short command that prints more than a pipe holds still comes back whole.
@Test func runReadsLongOutput() {
    #expect(
        Subprocess.printed(
            ["/bin/sh", "-c", "head -c 200000 /dev/zero | tr '\\0' y"], path: "/bin:/usr/bin", timeout: 5)?
            .count == 200_000)
}

/// Eighty pieces of slow work (git or ssh against a host that doesn't answer): the daemon still answers the next
/// request. On the global pool (64 threads, shared with Swift's own tasks) everything stopped.
@Test func aRequestIsAnsweredWhileManySlowOnesRun() async throws {
    let release = DispatchSemaphore(value: 0), held = 80
    let started = OSAllocatedUnfairLock(initialState: 0)
    let (d, _, root) = try daemon()
    defer {
        for _ in 0..<held { release.signal() }
        d.stop()
    }
    for _ in 0..<held {
        Task {
            try? await d.offload {
                started.withLock { $0 += 1 }
                release.wait()
            }
        }
    }
    #expect(try await waitFor(10) { started.withLock { $0 } == held })   // all of them running, holding their threads
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    Unix.writeAll(fd, try Wire.line(RPCRequest(id: 1, method: "session.list")))
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buf, buf.count)
    #expect(n > 0 && String(decoding: buf[0..<max(n, 0)], as: UTF8.self).contains("\"id\":1"))
}

/// Every offload slot held by slow work and more waiting for one: an agent's hook still comes through at once (its
/// `kelp hook` waits for the reply before the agent goes on). It used to wait for a slot behind all of them.
@Test func aHookIsAnsweredWhileEverySlotIsHeld() async throws {
    let release = DispatchSemaphore(value: 0), held = Daemon.offloadLimit + 10
    let started = OSAllocatedUnfairLock(initialState: 0)
    let (d, _, root) = try daemon()
    defer {
        for _ in 0..<held { release.signal() }
        d.stop()
    }
    for _ in 0..<held {
        Task {
            try? await d.offload {
                started.withLock { $0 += 1 }
                release.wait()
            }
        }
    }
    #expect(try await waitFor(10) { started.withLock { $0 } == Daemon.offloadLimit })   // every slot taken, the rest waiting
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    // Behind the held slots it would never come (they're let go only at the end): 30 s tells that apart from TSan's
    // slowness on a shared runner, where 3 s ran out
    var tv = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    Unix.writeAll(
        fd,
        try Wire.line(RPCRequest(id: 1, method: SessionHook.name, params: .obj(["id": "gone", "event": "working"]))))
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buf, buf.count)
    #expect(n > 0 && String(decoding: buf[0..<max(n, 0)], as: UTF8.self).contains("\"id\":1"))
}

/// The app's attach (JSON): the reply with the history comes before any live output, as with `kelp attach`.
@Test func jsonAttachSendsHistoryBeforeLiveOutput() async throws {
    let (d, c, w, root) = try await project()
    defer { d.stop() }
    let count = "i=0; while [ $i -lt 300000 ]; do i=$((i+1)); echo n$i; done; sleep 30"
    let s: Session = try await c.call(
        "session.create", .obj(["worktreeId": .string(w.id), "command": .string(count)]), as: Session.self)
    #expect(
        try await waitFor(10) {
            (try await c.call("session.read", .obj(["id": .string(s.id), "bytes": 100]))).string?.contains("n") == true
        })
    for _ in 0..<5 {   // several tries: each a race the old code lost most of the time
        let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        Unix.writeAll(
            fd, try Wire.line(RPCRequest(id: 1, method: "session.attach", params: .obj(["id": .string(s.id)]))))
        var got = "", buf = [UInt8](repeating: 0, count: 65536)
        while !got.contains("\"id\":1") {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            got += String(decoding: buf[0..<n], as: UTF8.self)
        }
        let reply = try #require(got.range(of: "\"id\":1"))
        #expect(!got[..<reply.lowerBound].contains("event.output"), "live output came before the history")
    }
}

/// A daemon that can't start (here another one serves this home) leaves its reason where the app's banner reads it, and
/// the next daemon that starts takes it away.
@Test func aDaemonThatCantStartSaysWhyWhereTheAppLooks() async throws {
    let root = tmp(), err = Paths.daemonError(in: root)
    let first = try Daemon(root: root)
    try first.start()
    let second = try Daemon(root: root)
    do {
        try second.start()
        Issue.record("a second daemon started on the same home")
        second.stop()
    } catch { _ = Daemon.startFailed(error, root: root) }   // what kelpd does with it
    #expect((try? String(contentsOf: err, encoding: .utf8))?.contains("another kelpd is already running") == true)
    first.stop()
    let started = try await restarted(root)   // what's tested here is the reason file, not when the lock goes
    #expect(!FileManager.default.fileExists(atPath: err.path))
    started.stop()
}

/// /resume in Claude Code switches the conversation: the hooks name the new one, and the session is pinned to it, so a
/// wake brings it back instead of the one Kelp started (an old conversation under the new one's title).
@Test func hooksMoveThePinToTheResumedConversation() async throws {
    var pinned = AgentManifest(id: "pinned", name: "Pinned", command: "/bin/bash", args: ["-c", "sleep 30", "x"])
    pinned.sessionIdFlag = "--session-id"
    pinned.resumeIdFlag = "--resume"
    let w = try await world(agents: [pinned])
    defer { w.d.stop() }
    let wt = try await workspace(w, "resumed")
    let s: Session = try await w.c.call(
        "session.create", .obj(["worktreeId": .string(wt.id), "agent": "pinned"]), as: Session.self)
    let other = UUID().uuidString.lowercased()
    func argv() async throws -> [String] {
        try await w.c.call("session.list", as: [Session].self).first { $0.id == s.id }?.argv ?? []
    }
    _ = try await w.c.call(
        "session.hook",
        .obj([
            "id": .string(s.id), "event": "working",
            "transcript": .string("/p/\(s.id.lowercased())/subagents/agent-a1.jsonl")
        ]))
    #expect(try await argv().contains(s.id.lowercased()))   // a subagent's file changes nothing
    _ = try await w.c.call(
        "session.hook", .obj(["id": .string(s.id), "event": "working", "transcript": .string("/p/\(other).jsonl")]))
    #expect(try await waitFor { try await argv().suffix(2) == ["--session-id", other] })
    _ = try await w.c.call("session.kill", .obj(["id": .string(s.id)]))
}
