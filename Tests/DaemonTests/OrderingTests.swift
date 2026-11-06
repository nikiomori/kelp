import Foundation
import os
import Testing
import Core
import Agents
@testable import Daemon

/// `calls` written to the daemon in one write, as one connection sends them back to back; every line read (events
/// included) until each has its reply and nothing more comes for half a second, at most 10 s.
/// `onLine`: each line as it comes.
private func sendAtOnce(_ root: URL, _ calls: [(String, JSONValue)], onLine: (JSONValue) -> Void = { _ in }) throws -> [JSONValue] {
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    var t = timeval(tv_sec: 10, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    var batch = Data()
    for (i, c) in calls.enumerated() { batch += try Wire.line(RPCRequest(id: i + 1, method: c.0, params: c.1)) }
    Unix.writeAll(fd, batch)
    var lb = LineBuffer(), buf = [UInt8](repeating: 0, count: 65536), lines: [JSONValue] = []
    var replied = false
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { break }
        let new = try lb.append(Data(buf[0..<n])).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        new.forEach(onLine)
        lines += new
        if !replied, lines.filter({ $0["id"] != nil }).count >= calls.count {   // then the events still on their way, for 0.5 s
            replied = true; t = timeval(tv_sec: 0, tv_usec: 500_000)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        }
    }
    return lines
}

/// A colour dragged or a stepper held sends settings.set after settings.set: they apply and answer in the order sent, so
/// the last one is what stays, in settings.json and in what the app hears. Each used to run on a thread of its own.
@Test func quickSettingsSetsApplyInTheOrderSent() async throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let n = 40
    let lines = try sendAtOnce(root, (1...n).map { (SettingsSet.name, .obj(["key": "terminal.fontSize", "value": .int(10 + $0)])) })
    #expect(lines.compactMap { $0["id"]?.int } == Array(1...n))
    let file = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
    #expect(file["terminal.fontSize"] == .int(10 + n))
    #expect(lines.last { $0["method"] == "event.settings" }?["params"]?["settings"]?["terminal.fontSize"] == .int(10 + n))
    // A set's event comes before its reply: the app stops holding the key back at the reply, so a later event would put an older value back.
    var heard = 0
    for line in lines {
        if let v = line["params"]?["settings"]?["terminal.fontSize"]?.int { heard = v }
        if let id = line["id"]?.int { #expect(heard >= 10 + id) }
    }
}

/// Sends written one after another reach the agent in that order. (A busy program gets queued text one at a time, once it
/// has been quiet a moment: a few sends take a while.)
@Test func sendsReachTheSessionInTheOrderSent() async throws {
    let w = try await world(); defer { w.d.stop() }
    let wt = try await workspace(w, "order")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, command: "stty -echo; echo ready; exec cat"))
    #expect(try await waitFor(10) { try await w.c.call(SessionRead(id: s.id)).contains("ready") })
    let n = 6
    _ = try sendAtOnce(w.root, (1...n).map { (SessionSend.name, .obj(["id": .string(s.id), "text": .string("m\($0)")])) })
    var got: [String] = []
    _ = try await waitFor(30) {
        got = try await w.c.call(SessionRead(id: s.id)).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("m") && Int($0.dropFirst()) != nil }
        return got.count == n
    }
    #expect(got == (1...n).map { "m\($0)" })
}

/// `kelp attach`'s control connection only sends sizes: once it says so (client.events), broadcasts skip it, as they
/// still reach every other client. Each open terminal used to be one more reader of every event.
@Test func aConnectionThatWantsNoEventsGetsNone() async throws {
    let (d, c, root) = try daemon(); defer { d.stop() }
    func heard(_ fd: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }
    func listener(muted: Bool) throws -> Int32 {
        let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
        var t = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        // Either way it says something first, and hears the answer: until the daemon read it, it could be a terminal's
        // byte stream (session.stream), which hears nothing. Another connection's call proves nothing about this one.
        let first = muted ? RPCRequest(id: 1, method: ClientEvents.name, params: .obj(["events": false])) : RPCRequest(id: 1, method: Ping.name)
        Unix.writeAll(fd, try Wire.line(first))
        #expect(heard(fd).contains("\"id\":1"))
        return fd
    }
    let quiet = try listener(muted: true), loud = try listener(muted: false)
    defer { close(quiet); close(loud) }
    _ = try await c.call(SettingsSet(key: "terminal.fontSize", value: .int(13)))   // broadcasts event.settings
    #expect(heard(loud).contains("event.settings"))
    #expect(heard(quiet).isEmpty)
}

/// `kelp attach` sends `session.stream` as its first line: an event broadcast between its connect and that line went into
/// what became the terminal's byte stream, and showed on screen as JSON.
@Test func anAttachingTerminalGetsNoEventBeforeItsStream() async throws {
    let (d, c, root) = try daemon(); defer { d.stop() }
    _ = try await c.call(Ping())
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    #expect(try await waitFor(5) { d.clients.everyone().count == 2 })
    d.notify(ChangedEvent.repo)   // while it hasn't said what it is
    Unix.writeAll(fd, try Wire.line(RPCRequest(id: nil, method: "session.stream", params: .obj(["id": "none"]))))
    var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    #expect(String(decoding: out, as: UTF8.self) == "kelp: no such session\r\n")
}

/// A paused agent that can't wake shows why in its terminal: it used to say "no such session" whatever went wrong.
@Test func aTerminalSaysWhyItsAgentDidntWake() async throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let s = Session(cwd: "/tmp", command: "gone", agent: "gone", status: .paused)
    try d.store.save(s)
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    Unix.writeAll(fd, try Wire.line(RPCRequest(id: nil, method: "session.stream", params: .obj(["id": .string(s.id)]))))
    var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    #expect(String(decoding: out, as: UTF8.self) == "kelp: unknown agent gone\r\n")
}

/// A send to a paused agent wakes it (git, files, a spawn) off the connection's reader thread: what that connection sends
/// next is answered meanwhile, and the send's own reply comes once the woken agent has the text. It used to wake on the
/// reader thread, so the app's next calls — and its main thread, once the socket filled — waited out the wake.
@Test func aSendToAPausedAgentDoesntHoldUpItsConnection() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "stty -echo; echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await workspace(w, "lane")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    try await hibernate(after: 0.03, w.c)   // ~2 s
    func status() async throws -> AgentStatus? { try await w.c.call(SessionList()).first { $0.id == s.id }?.status }
    #expect(try await waitFor(15) { try await status() == .paused })
    try await hibernate(after: 0, w.c)
    // A wake held up (its lock held elsewhere, as an idle pause holds it) until the ping is answered, not for a time a
    // slow machine (the Thread Sanitizer's) could outlast.
    let held = OSAllocatedUnfairLock(initialState: false), pinged = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        w.d.sessions.wakeLocks.withLock(s.id) {
            held.withLock { $0 = true }
            _ = pinged.wait(timeout: .now() + 30)
        }
    }
    #expect(try await waitFor(5) { held.withLock { $0 } })
    let calls: [(String, JSONValue)] = [(SessionSend.name, .obj(["id": .string(s.id), "text": "hello-lane"])), (Ping.name, .null)]
    let lines = try sendAtOnce(w.root, calls) { if $0["id"]?.int == 2 { pinged.signal() } }
    #expect(lines.contains { $0["id"]?.int == 2 && $0["result"] == "pong" })
    #expect(lines.compactMap { $0["id"]?.int } == [2, 1], "the ping waited for the wake")
    #expect(lines.contains { $0["id"]?.int == 1 && $0["result"] != nil })
    #expect(try await waitFor(15) { try await w.c.call(SessionRead(id: s.id)).contains("hello-lane") })
}

/// Input queued for a paused agent is typed once it wakes though its sender hung up meanwhile (`kelp session send`
/// past its deadline): checked again as the caller it came from, not as a connection that's gone (taken for a program
/// of the daemon's, which may not type).
@Test func inputQueuedByAGoneSenderIsStillTyped() async throws {
    let w = try await world(agents: [AgentManifest(id: "sleepy", name: "Sleepy", command: "/bin/zsh", args: ["-c", "stty -echo; echo ready; exec cat"],
                                                   resumeArgs: ["--resume"])]); defer { w.d.stop() }
    let wt = try await workspace(w, "gone")
    let s = try await w.c.call(SessionCreate(worktreeId: wt.id, agent: "sleepy"))
    try await hibernate(after: 0.03, w.c)   // ~2 s
    #expect(try await waitFor(15) { try await w.c.call(SessionList()).first { $0.id == s.id }?.status == .paused })
    try await hibernate(after: 0, w.c)
    let held = OSAllocatedUnfairLock(initialState: false), release = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        w.d.sessions.wakeLocks.withLock(s.id) {
            held.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 30)
        }
    }
    #expect(try await waitFor(5) { held.withLock { $0 } })
    // One ahead of it on the lane, which waits for the wake: what comes next is checked only once that one is through.
    let first = Task { try await w.c.call(SessionSend(id: s.id, text: "first ")) }
    #expect(try await waitFor(5) { !w.d.sessions.lanes.isClear(s.id) })
    let before = w.d.clients.everyone().count
    let fd = try Unix.connect(w.root.appendingPathComponent("kelp.sock").path)
    Unix.writeAll(fd, try Wire.line(RPCRequest(id: 1, method: SessionSend.name, params: .obj(["id": .string(s.id), "text": "hello-gone"]))))
    #expect(try await waitFor(5) { w.d.clients.everyone().count == before + 1 })
    close(fd)
    #expect(try await waitFor(5) { w.d.clients.everyone().count == before })   // its sender is gone
    release.signal()
    _ = try await first.value
    #expect(try await waitFor(15) { try await w.c.call(SessionRead(id: s.id)).contains("hello-gone") })
}

/// Only a sync `Handled` is applied in order (the reader thread can't wait for an async one): an async method marked
/// in-order would run on a task of its own, its order lost without a word.
@Test func inOrderMethodsAreSyncHandlers() {
    let inOrder = Daemon.methods.values.filter { $0.inOrder }
    #expect(inOrder.count >= 10)
    for t in inOrder { #expect(t is any Handled.Type, "\(t.name)") }
}

/// Each method is answered one of three ways, by its type: in order on the reader thread (everything sent after it waits),
/// quick on a thread of its own (no slot), or blocking in `offload`. The first two start no program. A new in-order one
/// holds up the connection's every call, so it's added here on purpose (a quick one usually does instead).
@Test func theInOrderMethodsAreTheKnownOnes() {
    let inOrder = Set(Daemon.methods.values.filter { $0.inOrder }.map { $0.name })
    let known: [any RPCMethod.Type] = [SessionWrite.self, SessionSend.self, SessionResize.self, UIPublish.self, StateSet.self, ClientEvents.self,
                                       SettingsSet.self, WatchStart.self, WatchStop.self, LSPOpen.self, LSPChange.self, LSPClose.self,
                                       DaemonUpgrade.self, DaemonShutdown.self]
    #expect(inOrder == Set(known.map { $0.name }))
    let both = Daemon.methods.values.compactMap { $0 as? any Handled.Type }.filter { $0.inOrder && $0.quick }.map { $0.name }
    #expect(both == [], "in order or quick, not both")
}

/// An in-order call is applied on the connection's reader thread, where whatever was sent after it waits: one that would
/// start a program (git, gh, ssh) fails at once instead of holding the connection up. Off that thread the same one runs.
@Test func anInOrderCallStartsNoProgram() async throws {
    let w = try await world(); defer { w.d.stop() }
    let p = JSONValue.obj(["id": .string(try await firstWorkspace(w).id)])
    #expect(throws: RPCError.self) { _ = try w.d.answerNow(GitStatus.self, p, conn: -1) }
    _ = try await w.d.answer(GitStatus.name, p, conn: -1)
}

/// A quick method (`Handled.quick`) doesn't wait for a slot behind slow programs, so it must start none: each one, called
/// on a running session as agents and the app call it, answers without (`Subprocess.quickOnly` would fail it). None is
/// in order as well: those are the reader thread's already.
@Test func quickMethodsStartNoProgram() async throws {
    let w = try await world(); defer { w.d.stop() }
    let workspace = try await firstWorkspace(w)
    let s = try await w.c.call(SessionCreate(worktreeId: workspace.id, command: "exec cat"))
    let quick = Daemon.methods.values.compactMap { $0 as? any Handled.Type }.filter { $0.quick }
    #expect(quick.count >= 10)
    let p = JSONValue.obj(["id": .string(s.id), "pane_id": .string(s.id), "event": "working", "state": "working", "summary": "x", "key": "k", "cwd": .string(workspace.path),
                           "transcript": .string("/tmp/\(UUID().uuidString.lowercased()).jsonl")])
    for t in quick {
        let ordered = t.inOrder; #expect(!ordered, "\(t.name)")
        do { _ = try await w.d.answer(t.name, p, conn: -1) } catch let e as RPCError where e.message.hasPrefix("Only Kelp's window") {
            continue   // refused before anything ran: only the window may call it
        } catch { Issue.record("\(t.name): \(error)") }
    }
    let status = JSONValue.obj(["id": .string(workspace.id)])   // and one that runs git can't go that way
    await #expect(throws: RPCError.self) { _ = try await w.d.offload(quick: true) { try GitStatus.answerNow(status, w.d, conn: -1) } }
}

/// A burst of offloaded work (git, gh, ssh) runs at most `offloadLimit` at once; the rest wait their turn, and all of it
/// finishes. Each used to get a thread at once, however many came.
@Test func offloadRunsAtMostItsLimitAtOnce() async throws {
    let (d, _, _) = try daemon(); defer { d.stop() }
    let now = OSAllocatedUnfairLock(initialState: (running: 0, most: 0, done: 0))
    try await withThrowingTaskGroup(of: Void.self) { g in
        for _ in 0..<(Daemon.offloadLimit * 3) {
            g.addTask {
                try await d.offload {
                    now.withLock { $0.running += 1; $0.most = max($0.most, $0.running) }
                    usleep(20_000)
                    now.withLock { $0.running -= 1; $0.done += 1 }
                }
            }
        }
        try await g.waitForAll()
    }
    let seen = now.withLock { $0 }
    #expect(seen.most <= Daemon.offloadLimit && seen.most > 1, "\(seen)")
    #expect(seen.done == Daemon.offloadLimit * 3)
}

/// `printf '…' | nc -U kelp.sock`: the client closes its side once it has asked; the answer still comes.
@Test func aClientThatStopsSendingIsStillAnswered() throws {
    let (d, _, root) = try daemon(); defer { d.stop() }
    let fd = try Unix.connect(root.appendingPathComponent("kelp.sock").path)
    defer { close(fd) }
    var t = timeval(tv_sec: 10, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    Unix.writeAll(fd, try Wire.line(RPCRequest(id: 1, method: "session.list", params: nil)))
    shutdown(fd, SHUT_WR)
    var got = Data(), buf = [UInt8](repeating: 0, count: 65536)
    while true { let n = read(fd, &buf, buf.count); guard n > 0 else { break }; got += Data(buf[0..<n]) }
    #expect(String(decoding: got, as: UTF8.self).contains(#""id":1"#))
}
