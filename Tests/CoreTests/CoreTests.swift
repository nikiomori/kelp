import Foundation
import TestSupport
import Testing
import os

@testable import Core

@Test func lineBufferSplitsAcrossChunks() {
    var b = LineBuffer()
    #expect(b.append(Data("{\"a\":".utf8)).isEmpty)
    let lines = b.append(Data("1}\n{\"b\":2}\nrest".utf8))
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
    #expect(b.append(Data("\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["rest", ""])
    // A long line in small reads comes out whole, once.
    let long = String(repeating: "x", count: 100_000)
    var got: [Data] = []
    for chunk in Data((long + "\nnext").utf8).chunked(8192) { got += b.append(chunk) }
    #expect(got.map { String(decoding: $0, as: UTF8.self) } == [long])
    #expect(String(decoding: b.takeRemainder(), as: UTF8.self) == "next")
}

private extension Data {
    func chunked(_ n: Int) -> [Data] { stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] } }
}

@Test func jsonValueKeepsEachType() throws {
    let text = #"{"n":null,"b":true,"i":3,"d":2.5,"s":"x","a":[1,"y",false],"o":{"k":[]}}"#
    let v = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(
        v
            == .object([
                "n": .null, "b": .bool(true), "i": .int(3), "d": .double(2.5), "s": .string("x"),
                "a": .array([.int(1), .string("y"), .bool(false)]), "o": .object(["k": .array([])])
            ]))
    #expect(v["i"]?.number == 3 && v["d"]?.number == 2.5 && v["s"]?.number == nil)   // either kind of number, nothing else
}

@Test func callTimesOutWhenNoReplyComes() async throws {
    let path = NSTemporaryDirectory() + "kelp-timeout-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    defer { close(peer) }
    await #expect(throws: RPCError.self) { try await client.call("usage.get", timeout: 0.2) }
    // The late reply finds nobody waiting (no second resume), and the next call still gets its own.
    let late = try Wire.line(JSONValue.obj(["id": 1, "result": .null])),
        next = try Wire.line(JSONValue.obj(["id": 2, "result": "ok"]))
    // Sent once both requests came (usage.get, then ping): ahead of the ping it would find no call waiting for it.
    Thread.detachNewThread {   // its own thread: a blocking read on GCD's pool started late when the suite filled it
        var byte: UInt8 = 0, lines = 0
        while lines < 2, read(peer, &byte, 1) == 1 { if byte == 0x0A { lines += 1 } }
        Unix.writeAll(peer, late + next)
    }
    #expect(try await client.call("ping", timeout: 5).string == "ok")
}

/// A socket someone still answers on isn't taken over; a stale one (its owner gone) is.
@Test func listenLeavesALiveSocketAlone() throws {
    let path = NSTemporaryDirectory() + "kelp-live-\(getpid()).sock"
    let first = try Unix.listen(path)
    #expect(throws: (any Error).self) { try Unix.listen(path) }
    close(first)
    // The file is still there, nobody behind it: taken over. (A process being started elsewhere in the test run holds a
    // copy of every fd for a moment, so not necessarily on the first try.)
    var again: Int32 = -1
    for _ in 0..<100 where again < 0 {
        again = (try? Unix.listen(path)) ?? -1
        if again < 0 { usleep(20_000) }
    }
    #expect(again >= 0)
    close(again)
    unlink(path)
}

@Test func jsonValueRoundTrip() throws {
    let v = try JSONValue.from(RPCRequest(id: 1, method: "x", params: .object(["k": .string("v")])))
    #expect(v["method"]?.string == "x")
    #expect(v["params"]?["k"]?.string == "v")
}

/// Typed methods put the JSON on the wire that the hand-written calls they replaced did, and read today's answers.
@Test func typedMethodsKeepTheWireFormat() throws {
    #expect(try DaemonInfo().params() == nil)
    #expect(try StateGet(prefix: "").params() == .obj(["prefix": ""]))
    #expect(try StateGet(key: "k").params() == .obj(["key": "k"]))
    #expect(try StateSet(key: "k", value: .array(["a"])).params() == .obj(["key": "k", "value": .array(["a"])]))
    #expect(try StateSet(key: "k", value: nil).params() == .obj(["key": "k"]))   // a missing value deletes, as null does
    #expect(try SessionRename(id: "s", title: "t").params() == .obj(["id": "s", "title": "t"]))
    #expect(try SessionContextWindow(id: "s").params() == .obj(["id": "s"]))
    #expect(try WorktreeNote(id: "w", note: "n").params() == .obj(["id": "w", "note": "n"]))

    let info = try JSONValue.obj(["path": "/k/kelpd", "binaryMTime": 1_760_000_000, "pid": 7, "liveSessions": 2])
        .decode(DaemonInfo.Result.self)
    #expect(info.path == "/k/kelpd" && info.binaryMTime == 1_760_000_000 && info.liveSessions == 2)   // a whole double arrives as an int
    #expect(
        try JSONValue.obj(["path": "/k", "pid": 7, "liveSessions": 0]).decode(DaemonInfo.Result.self).binaryMTime == nil
    )
    #expect(
        try JSONValue.obj(["used": 10, "window": 100]).decode(SessionContextWindow.Result.self)
            == .init(used: 10, window: 100))
    #expect(try JSONValue.null.decode(SessionContextWindow.Result.self) == nil)
    #expect(try JSONValue.from(Done()) == .null)
    _ = try JSONValue.null.decode(Done.self)
}

@Test func ghosttyConfigParse() {
    let c = GhosttyConfig.parse(
        "# comment\nbackground = #1e1e2e\nforeground=cdd6f4\nfont-family = \"JetBrains Mono\"\nfont-size = 14\npalette = 1=#f38ba8\n"
    )
    #expect(
        c.background == "#1e1e2e" && c.foreground == "cdd6f4" && c.fontFamily == "JetBrains Mono" && c.fontSize == 14
            && c.palette[1] == "#f38ba8")
    #expect(GhosttyConfig.rgb("#ff0000")! == (1, 0, 0))
}

@Test func knownErrorsCarryTheirFix() {
    #expect(
        FixRecipes.fix(for: "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)")
            == .init(command: "xcode-select --install", blocking: true))
    #expect(FixRecipes.fix(for: "You have not agreed to the Xcode license agreements.")?.blocking == true)
    #expect(
        FixRecipes.fix(for: "fatal: The current branch x has no upstream branch.")?.command == "git push -u origin HEAD"
    )
    #expect(FixRecipes.fix(for: "everything is fine") == nil)
}

@Test func aSocketIsPrivateToItsOwner() throws {
    let dir = NSTemporaryDirectory() + "kelp-priv-\(getpid())"
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let path = dir + "/k.sock"
    let fd = try Unix.listen(path)
    defer {
        close(fd)
        try? FileManager.default.removeItem(atPath: dir)
    }
    func mode(_ p: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int) ?? -1
    }
    #expect(mode(path) == 0o600)
    #expect(mode(dir) == 0o700)   // our own folder is closed off, so nothing could reach the socket before its chmod
}

@Test func aSharedFolderIsNotChangedForASocket() throws {
    let before = ((try? FileManager.default.attributesOfItem(atPath: "/tmp"))?[.posixPermissions] as? Int) ?? 0
    let path = "/tmp/kelp-shared-\(getpid()).sock"
    let fd = try Unix.listen(path)
    defer {
        close(fd)
        unlink(path)
    }
    #expect(((try? FileManager.default.attributesOfItem(atPath: "/tmp"))?[.posixPermissions] as? Int) == before)   // sticky and not ours: left alone
}

@Test func onlyOurOwnProcessesAreAcceptedOnTheSocket() throws {
    let path = NSTemporaryDirectory() + "kelp-peer-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let client = try Unix.connect(path)
    let peer = accept(server, nil, nil)
    defer {
        close(client)
        close(peer)
    }
    #expect(Unix.peerIsUs(peer))
    #expect(!Unix.peerIsUs(-1))   // not a connection at all: refused, not trusted
}

@Test func keychainSetUpdatesInPlaceAndDeleteRemoves() throws {
    _ = TestIsolation.root   // never the real keys, even if one was inherited
    let account = "kelp-test-\(UUID().uuidString)"
    defer { Keychain.delete(account) }
    #expect(Keychain.get(account) == nil)
    try Keychain.set("one", account: account)
    #expect(Keychain.get(account) == "one")
    try Keychain.set("two", account: account)   // the second set updates, it doesn't fail on the existing item
    #expect(Keychain.get(account) == "two")
    Keychain.delete(account)
    #expect(Keychain.get(account) == nil)
}

/// The app installs its handlers after connecting (with awaits in between): a daemon that drops first must still be noticed.
@Test func aCloseHandlerInstalledAfterTheDropStillRuns() async throws {
    let path = NSTemporaryDirectory() + "kelp-late-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    close(peer)   // the daemon goes away before anyone listens for that
    await #expect(throws: (any Error).self) { _ = try await client.call("ping", timeout: 5) }   // the reader has seen the close
    let told = Flag()
    client.onClose = { told.set() }
    #expect(told.value)   // installed late, run at once
}

@Test func notificationsReachAHandlerSetWhileReading() async throws {
    let path = NSTemporaryDirectory() + "kelp-note-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    defer { close(peer) }
    let got = Flag()
    client.onNotification = { m, _ in if m == "event.test" { got.set() } }
    Unix.writeAll(peer, try Wire.line(RPCRequest(id: nil, method: "event.test", params: nil)))
    #expect(try await waitFor(5) { got.value })
    #expect(got.value)
}

/// An event comes to `onEvent` as its own type, read once on the reader thread (the app's main thread decodes nothing).
@Test func eventsComeAsTheirTypes() async throws {
    let path = NSTemporaryDirectory() + "kelp-ev-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    defer { close(peer) }
    let got = OSAllocatedUnfairLock<[any RPCEvent]>(initialState: [])
    client.onEvent = { e in got.withLock { $0.append(e) } }
    Unix.writeAll(peer, try Wire.line(RPCNotification(RemovedEvent(session: "s1"))))
    Unix.writeAll(peer, try Wire.line(RPCRequest(id: nil, method: "event.unknown", params: nil)))   // not one of `rpcEvents`
    Unix.writeAll(peer, try Wire.line(RPCNotification(CloneEvent(id: "c", line: "done"))))
    #expect(try await waitFor(5) { !(got.withLock({ $0.count }) < 2) })
    let events = got.withLock { $0 }
    #expect(events.count == 2)
    #expect(events.first as? RemovedEvent == RemovedEvent(session: "s1"))
    #expect((events.last as? CloneEvent)?.line == "done")
}

/// The caller (the app's main thread) never waits on a full socket: writes are queued, and go out whole and in the
/// order they were made once the daemon reads again. Before, the eighth megabyte waited for the daemon to read.
@Test func writesDontWaitForTheDaemonToRead() async throws {
    let path = NSTemporaryDirectory() + "kelp-full-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let client = try RPCClient(socket: path)
    let peer = accept(server, nil, nil)
    defer { close(peer) }
    let sent = Flag(), pad = JSONValue.string(String(repeating: "x", count: 1 << 20))
    Thread.detachNewThread {
        for i in 0..<8 { client.notify("big", .obj(["i": .int(i), "pad": pad])) }   // far more than the socket holds
        sent.set()
    }
    #expect(try await waitFor(5) { sent.value })
    #expect(sent.value)   // before the daemon read a byte
    var lb = LineBuffer(), order: [Int] = [], buf = [UInt8](repeating: 0, count: 65536)
    while order.count < 8 {
        let n = read(peer, &buf, buf.count)
        if n <= 0 { break }
        for line in lb.append(Data(buf[0..<n])) {
            order.append(try JSONDecoder().decode(JSONValue.self, from: line)["params"]?["i"]?.int ?? -1)
        }
    }
    #expect(order == Array(0..<8))
}

final class Flag: @unchecked Sendable {   // the bool under lock
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}

/// The app doesn't ignore SIGPIPE: writing to a daemon that went away must fail, not kill the process (the test would die).
@Test func writingToAGoneDaemonFailsInsteadOfKillingTheProcess() throws {
    let path = NSTemporaryDirectory() + "kelp-pipe-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    let old = signal(SIGPIPE, SIG_DFL)   // as in the app: SIGPIPE would end the process
    defer { signal(SIGPIPE, old) }
    let fd = try Unix.connect(path)
    defer { close(fd) }
    close(accept(server, nil, nil))   // the daemon side goes away
    let big = Data(repeating: 0x41, count: 1 << 20)
    var failed = false
    for _ in 0..<4 where !failed { failed = !Unix.writeAll(fd, big) }
    #expect(failed)   // the write reports it; we're still here
}

/// A client closed while its reader waits must not read the next connection's replies (closing the fd under the reader
/// let the number be reused). Many rounds of close-then-reconnect: every new connection gets its own answer.
@Test func aClosedClientNeverReadsTheNextConnectionsReplies() async throws {
    let path = NSTemporaryDirectory() + "kelp-reuse-\(getpid()).sock"
    let server = try Unix.listen(path)
    defer {
        close(server)
        unlink(path)
    }
    for round in 0..<50 {
        let old = try RPCClient(socket: path)
        let oldPeer = accept(server, nil, nil)
        old.close()
        let fresh = try RPCClient(socket: path)
        let peer = accept(server, nil, nil)
        // Answered once the request came: a reply sent before it would find no call waiting and be dropped (on a busy
        // machine it did, and the test timed out).
        Thread.detachNewThread {   // its own thread: a blocking read on GCD's pool started late when the suite filled it
            var byte: UInt8 = 0
            while read(peer, &byte, 1) == 1, byte != 0x0A {}
            Unix.writeAll(peer, (try? Wire.line(JSONValue.obj(["id": 1, "result": .string("r\(round)")]))) ?? Data())
        }
        #expect(try await fresh.call("ping", timeout: 5).string == "r\(round)")
        fresh.close()
        close(peer)
        close(oldPeer)
    }
}

@Test func lockedKeepsEveryChangeFromManyThreads() async {
    let n = OSAllocatedUnfairLock(initialState: 0)
    await withTaskGroup(of: Void.self) { g in for _ in 0..<1000 { g.addTask { n.withLock { $0 += 1 } } } }
    #expect(n.withLock { $0 } == 1000)
}

/// A tmux terminal is known by its argv; names come out as tmux keeps them; list-sessions lines parse, the rest is skipped.
@Test func tmuxSessionsAndNames() {
    #expect(Tmux.session(Tmux.argv("work")) == "work")
    #expect(Tmux.session(["tmux", "attach", "-t", "work"]) == nil && Tmux.session(["/bin/zsh", "-l"]) == nil)
    #expect(Tmux.name("  my.app:1 ") == "my_app_1")
    let out = "Welcome to the host\nold:1:0:100\nnew:3:1:200\nbad:x:0:1\n"
    #expect(
        Tmux.parse(out) == [
            Tmux.Session(name: "new", windows: 3, attached: 1, activity: Date(timeIntervalSince1970: 200)),
            Tmux.Session(name: "old", windows: 1, attached: 0, activity: Date(timeIntervalSince1970: 100))
        ])
    #expect(Tmux.noServer("no server running on /tmp/tmux-501/default") && !Tmux.noServer("tmux: command not found"))
    let own = Tmux.own()
    #expect(Tmux.isOwn(own) && Tmux.name(own) == own && own != Tmux.own())
    #expect(!Tmux.isOwn("kelp_test") && !Tmux.isOwn("kelp-tab-2") && !Tmux.isOwn("kelp-2"))
}

/// The login shell's PATH is read once, and an in-order call (`resolveNow`) doesn't wait for that read. Where no program
/// may start (`Subprocess.quickOnly`) the shell doesn't run, and that non-answer isn't kept: the next caller reads.
@Test func theLoginPathIsReadOnceAndQuickCallersDontWaitForIt() async throws {
    let gate = DispatchSemaphore(value: 0)
    let once = LoginPath.Once {
        gate.wait()
        return "/read"
    }
    Thread.detachNewThread { _ = once.value }
    #expect(once.ifRead == nil)   // still reading: asked now, there's no answer rather than a wait
    gate.signal()
    var waited = 0
    while once.ifRead == nil, waited < 250 {
        try await Task.sleep(for: .milliseconds(20))
        waited += 1
    }
    #expect(once.ifRead == "/read" && once.value == "/read")

    let dir = NSTemporaryDirectory() + "kelp-shell-\(UUID().uuidString.prefix(6))", shell = dir + "/sh",
        ran = dir + "/ran"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "#!/bin/sh\ntouch '\(ran)'\nprintf '__KELP__/from/shell__KELP__'\n".write(
        toFile: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell)
    #expect(Subprocess.quickOnly { LoginPath.shellPath(shell: shell) } == nil)
    #expect(!FileManager.default.fileExists(atPath: ran))   // refused before it started
    #expect(LoginPath.shellPath(shell: shell) == "/from/shell")
    let refused = LoginPath.Once { nil }
    #expect(refused.value == LoginPath.path("") && refused.ifRead == nil)
}

/// After an installer, the shell is asked again and the new PATH replaces the old; an answer that isn't one keeps the old.
@Test func theLoginPathIsReadAgainAfterAnInstallerButNotForAFailedRead() {
    let once = LoginPath.Once { "/old" }
    #expect(once.value == "/old")
    LoginPath.reread(once, from: nil)
    LoginPath.reread(once, from: "")
    #expect(once.value == "/old")
    LoginPath.reread(once, from: "/home/me/.grok/bin:/usr/bin")
    #expect(once.value.hasPrefix("/home/me/.grok/bin:/usr/bin") && once.value != "/old")
}

/// A reply in the daemon's layout is matched to its call from its first bytes; anything else goes to the full decode.
@Test func aRepliesIdIsReadFromItsFirstBytes() {
    func id(_ s: String) -> Int? { RPCClient.resultID(Data(s.utf8)) }
    #expect(id(#"{"jsonrpc":"2.0","id":42,"result":{"big":[1,2,3]}}"#) == 42)
    #expect(id(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"no"}}"#) == nil)
    #expect(id(#"{"jsonrpc":"2.0","method":"event.session","params":{}}"#) == nil)
    #expect(id(#"{"jsonrpc":"2.0","id":"7","result":1}"#) == nil)
    #expect(id(#"{"id":7,"jsonrpc":"2.0","result":1}"#) == nil)
    #expect(id(#"{"jsonrpc":"2.0","id":"#) == nil)
}

/// Closing the connection to a daemon that's alive but no longer reads ends it now: the close used to wait behind a
/// write blocked on that daemon, for good, so the app never heard the connection end and never reconnected.
@Test func closingAConnectionToAHungDaemonEndsIt() throws {
    let path = tmp().appendingPathComponent("s.sock").path
    let listener = try Unix.listen(path)
    defer { Darwin.close(listener) }   // accepts nothing, reads nothing
    let c = try RPCClient(socket: path)
    #expect(c.daemonPID == getpid())   // known without an answer: Restart Background Service stops a hung one by it
    let ended = DispatchSemaphore(value: 0)
    c.onClose = { ended.signal() }
    c.notify("x", .string(String(repeating: "x", count: 4 << 20)))   // more than the socket holds: the write blocks
    Thread.sleep(forTimeInterval: 0.3)
    c.close()
    #expect(ended.wait(timeout: .now() + 3) == .success)
}

/// An Android module's launcher icon; a site's favicon under the project's name, not another brand's.
@Test func iconSearchFindsLauncherAndProjectNamedIcons() {
    func find(_ repo: String, _ tree: [String: [String]]) -> String? { IconSearch.find(in: repo, list: { tree[$0] }) }
    #expect(
        find(
            "/p/Agro",
            [
                "/p/Agro": ["app", "logo-full.svg"], "/p/Agro/app/": ["src"],
                "/p/Agro/app/src/main/res/mipmap-xxxhdpi/": ["ic_launcher.png", "ic_launcher_round.png"]
            ])
            == "/p/Agro/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png")
    #expect(
        find(
            "/p/Pretype_lending",
            [
                "/p/Pretype_lending": ["public", "icons-qa.png"], "/p/Pretype_lending/public/": ["assets"],
                "/p/Pretype_lending/public/assets/": [
                    "github-icon.svg", "og.png", "pretype-icon.svg", "pretype-logo.png"
                ]
            ])
            == "/p/Pretype_lending/public/assets/pretype-icon.svg")
    #expect(find("/p/site", ["/p/site": ["public"], "/p/site/public/": ["github-icon.svg", "site.css"]]) == nil)
    // A home folder with projects in it: theirs aren't its own.
    #expect(
        find("/home/niko", ["/home/niko": ["nikiomori_CV"], "/home/niko/nikiomori_CV/": [".git", "favicon.svg"]]) == nil
    )
}

/// When a routine is due next: weekdays skip the weekend, weekly keeps its day, hourly its minute; a time the clocks skip
/// (spring forward) runs at the next one that exists.
@Test func routinesAreDueOnTheirSchedule() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    func at(_ s: String) throws -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return try #require(f.date(from: s))
    }
    func next(_ every: Routine.Every, _ time: Int, weekday: Int = 2, after: String) throws -> Date? {
        Routine(name: "r", repoId: "p", agent: "a", prompt: "x", every: every, time: time, weekday: weekday).next(
            after: try at(after), calendar: cal)
    }
    #expect(try next(.weekdays, 9 * 60, after: "2026-10-30 10:00") == at("2026-11-02 09:00"))   // Friday → Monday
    #expect(try next(.weekdays, 9 * 60, after: "2026-10-29 08:59") == at("2026-10-29 09:00"))
    #expect(try next(.weekly, 10 * 60, weekday: 2, after: "2026-10-27 10:00") == at("2026-11-02 10:00"))   // Mondays
    #expect(try next(.hourly, 15, after: "2026-10-29 11:14") == at("2026-10-29 11:15"))
    #expect(try next(.hourly, 15, after: "2026-10-29 11:15") == at("2026-10-29 12:15"))
    #expect(try next(.daily, 2 * 60 + 30, after: "2026-03-08 00:00") == at("2026-03-08 03:00"))   // no 2:30 that night
    let r = Routine(name: "r", repoId: "p", agent: "a", prompt: "x", every: .daily, time: 9 * 60)
    #expect(try r.times(after: at("2026-10-26 08:00"), through: at("2026-10-29 09:00"), calendar: cal).count == 4)
}

@Test func childrenReachDownThroughTheTree() {
    func one(_ id: String, _ parent: String?) -> Session {
        var s = Session(id: id, cwd: "/", command: "")
        s.parent = parent
        return s
    }
    #expect([one("a", nil), one("b", "a"), one("c", "b")].children(of: "a").map(\.id) == ["b", "c"])
}

@Test func theAgentBoardPutsWhoNeedsYouFirst() {
    let repo = Repo(id: "r", name: "kelp", path: "/p"), w = Worktree(id: "w", repoId: "r", branch: "main", path: "/p")
    func agent(_ id: String, _ status: AgentStatus, at t: Double, kind: String? = "claude") -> Session {
        Session(
            id: id, worktreeId: "w", cwd: "/p", command: "", agent: kind, status: status,
            createdAt: Date(timeIntervalSince1970: t), title: id)
    }
    var child = agent("child", .waiting, at: 3)
    child.parent = "first"
    child.summary = "Allow rm?\u{1B}]52;c;x\u{7}"
    let all = [
        agent("first", .working, at: 1), agent("second", .working, at: 2), child, agent("gone", .exited, at: 4),
        agent("paused", .paused, at: 5), agent("term", .working, at: 6, kind: "shell"), agent("done", .done, at: 7)
    ]
    let rows = AgentBoard.rows(all, worktrees: [w], repos: [repo])
    #expect(rows.map(\.id) == ["child", "first", "second", "done"])
    #expect(rows[0].title == "first › child")
    #expect(
        rows[0].detail == "Needs you · kelp · Allow rm? ]52;c;x ",
        "an escape in what an agent printed isn't sent to the terminal")
    #expect(AgentBoard.paused(all) == 1)
}

/// `kelp schema`, from the document that ships: a method by name, a type by part of its, and what isn't there.
@Test func theSchemaReadsAsText() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Core/Resources/rpc.json")
    let doc = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
    let choose = RPCSchema.text(doc, "session.choose").components(separatedBy: "\n")
    #expect(choose.first == "session.choose")
    #expect(choose.contains { $0.hasPrefix("  answer") && $0.contains("string") && $0.contains("required") })
    #expect(choose.last == "→ boolean")
    #expect(
        RPCSchema.text(doc, "agentstatus") == "AgentStatus: "
            + AgentStatus.allCases.map(\.rawValue).joined(separator: ", "))
    #expect(RPCSchema.text(doc, "session.lis").hasPrefix("session.list"))
    #expect(RPCSchema.text(doc, "nope") == "Nothing named nope")
    #expect(RPCSchema.text(doc, "state.get").contains("Kelp's own"))
    let all = RPCSchema.text(doc)
    #expect(try #require(all.range(of: "session.list")).lowerBound < #require(all.range(of: "lsp.open")).lowerBound)   // ours come last
}

/// tmux stops at a command that fails: `allow-passthrough`, which a tmux before 3.3 doesn't know, has to come last. What
/// agents report goes out first, before tmux takes over the terminal.
@Test func aConnectionToAHostStartsWithTheReportItMissed() throws {
    let c = RemoteHost(host: "box", path: "~/p").command(["claude"], inTmux: "kelp-tab-1")
    #expect(c.contains("allow-passthrough"))
    #expect(
        try #require(c.range(of: "set-titles-string")).lowerBound
            < #require(c.range(of: "allow-passthrough")).lowerBound)
    #expect(
        try #require(c.range(of: RemoteHost.statusOption)).lowerBound < #require(c.range(of: "new-session")).lowerBound)
}

/// A command's short name, from commands agents really ran.
@Test func aCommandIsCalledByItsProgram() {
    for (command, name) in [
        ("swift build --scratch-path /tmp/kelp-build/A --product kelp > /private/tmp/out.log 2>&1", "swift build"),
        ("cd /private/tmp/claude-501/x && swift test --filter 'AgentsTests|CoreTests'", "swift test"),
        ("export KELP_V1='release'; make release", "make release"),
        ("/private/tmp/claude-501/scratchpad/run.sh 2>&1 | tee run.out", "run.sh"),
        ("./Scripts/make-app.sh", "make-app.sh"),
        ("for i in 1 2 3; do swift test --filter x; done", "swift test"),
        ("KELP_HOME=/tmp/k /tmp/debug/KelpApp", "KelpApp"),
        ("npm run dev -- --port 3000", "npm run dev"),
        ("python3 -m pytest", "python3"),
        ("sleep 30", "sleep"),
        ("(cd web && pnpm build)", "pnpm build"),
        ("exec cat", "cat"),
        ("cd /tmp", "cd /tmp")
    ] { #expect(CommandName.of(command) == name, "\(command)") }
}

/// Each folder keeps its own ten ports, the same each run, and two folders never share a block.
@Test func everyFolderHasItsOwnPorts() {
    let folders = (1...200).map { "/projects/app-\($0)" }
    let ports = folders.map { PortBlocks.port(for: $0, among: folders) }
    #expect(Set(ports).count == folders.count)
    #expect(ports.allSatisfy { $0 >= 20_000 && $0 + 9 < 49_152 && $0 % 10 == 0 })   // under the ephemeral range
    #expect(PortBlocks.first + PortBlocks.count * PortBlocks.size <= 49_152)
    #expect(PortBlocks.port(for: folders[7], among: folders.reversed()) == ports[7])   // not the list's order
}

/// kelp ext check names each mistake and where it is; a sound extension has none.
@Test func anExtensionsMistakesAreNamedWithWhereTheyAre() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func write(_ json: String) throws {
        try json.write(to: dir.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
    }
    try write(#"{"id":"x","name":"X","contributes":{"panels":[{"id":"p","title":"P","web":"index.html"}]}}"#)
    try "<p>hi</p>".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    #expect(ExtCheck.problems(in: dir).isEmpty)
    try write(
        #"{"id":"x","nmae":"X","contributes":{"panels":[{"id":"p","title":"P"}],"commands":[{"title":"Go","run":"a","open":"b"}]}}"#
    )
    let found = ExtCheck.problems(in: dir)
    #expect(found.contains("“name” is missing: a non-empty string.") && found.contains("Unknown key “nmae” (a typo?)."))
    #expect(found.contains("contributes.panels[0]: needs exactly one of “list” or “web”."))
    #expect(found.contains("contributes.commands[0]: needs exactly one of terminal, run, open, agent (has run, open)."))
    try write("{ not json")
    #expect(ExtCheck.problems(in: dir).first?.hasPrefix("extension.json isn't valid JSON") == true)
}

/// The bridge and its TypeScript say the same things, and an ext: link's query reaches the page as props.
@Test func theBridgeAndItsTypesAgree() {
    let script = ExtBridge.script(props: ["file": "a.txt"])
    for name in [
        "exec", "terminal", "open", "agent", "run", "notify", "badge", "settings", "on", "sessions", "props",
        "workspace"
    ] {
        #expect(script.contains("\(name):") && ExtBridge.declarations.contains("\(name)"), "\(name)")
    }
    #expect(script.contains(#"props: {"file":"a.txt"}"#))
    let (view, props) = ExtBridge.split("my.ext/view?file=a%20b.txt&line=3")
    #expect(view == "my.ext/view" && props == ["file": "a b.txt", "line": "3"])
    #expect(ExtBridge.split("my.ext/view").props.isEmpty)
}

/// An install takes the bytes the library reviewed or nothing: a changed, missing or extra file is named.
@Test func onlyTheReviewedBytesInstall() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("web"), withIntermediateDirectories: true)
    try "{}".write(to: dir.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
    try "<p>hi</p>".write(to: dir.appendingPathComponent("web/index.html"), atomically: true, encoding: .utf8)
    try #"{"source":"x"}"#.write(to: dir.appendingPathComponent(IDE.sourceFile), atomically: true, encoding: .utf8)   // Kelp's own
    var files = ["extension.json": IDE.sha256(Data("{}".utf8)), "web/index.html": IDE.sha256(Data("<p>hi</p>".utf8))]
    #expect(IDE.differing(dir, from: files) == nil)
    files["web/index.html"] = IDE.sha256(Data("<p>other</p>".utf8))
    #expect(IDE.differing(dir, from: files) == "web/index.html")
    files["web/index.html"] = IDE.sha256(Data("<p>hi</p>".utf8))
    files["gone.js"] = "00"
    #expect(IDE.differing(dir, from: files) == "gone.js")
    files["gone.js"] = nil
    files["extension.json"] = nil
    #expect(IDE.differing(dir, from: files) == "extension.json")   // in the folder, not in the list
}

/// The library adds what community.json beside its index lists, as not reviewed, without what it reviewed itself.
@Test func theLibraryAddsTheCommunityAsUnreviewed() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try
        #"[{"id":"docker","name":"Docker","version":"1.0.0","source":"https://github.com/o/r/tree/t/extensions/docker"}]"#
        .write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
    try
        #"[{"id":"docker","name":"Fake","version":"9","source":"https://github.com/x/docker"},{"id":"memo","name":"Memo","version":"0.1.0","source":"https://github.com/a/memo/tree/abc","stars":12,"weekly":3}]"#
        .write(to: dir.appendingPathComponent("community.json"), atomically: true, encoding: .utf8)
    let all = try IDE.library(index: dir.appendingPathComponent("index.json").absoluteString)
    #expect(all.map(\.id) == ["docker", "memo"] && all[0].name == "Docker" && all[0].reviewed == nil)
    #expect(all[1].reviewed == false && all[1].weekly == 3)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("community.json"))
    #expect(try IDE.library(index: dir.appendingPathComponent("index.json").absoluteString).count == 1)
}

/// A declared setting reads its default while settings.json doesn't have it, the stored value when it does, and its
/// default again when the stored one is of another type (a string where a switch goes).
@Test func aSettingReadsItsDefaultUnlessStoredAsItsType() {
    let wrap = Setting("editor.wordWrap", false), size = Setting<Double>("editor.fontSize", 13)
    #expect(wrap.read(in: [:]) == false && size.read(in: [:]) == 13)
    #expect(wrap.read(in: ["editor.wordWrap": .bool(true)]) == true)
    #expect(size.read(.int(14)) == 14 && size.read(.double(13.5)) == 13.5)
    #expect(wrap.read(.string("yes")) == false && size.read(.string("big")) == 13)
    // A list keeps what's of its type; an optional one tells unset (nil) from empty.
    let off = Setting<[String]?>("extensions.disabled", nil)
    #expect(off.read(nil) == nil && off.read(.array([])) == [])
    #expect(off.read(.array([.string("a"), .int(1)])) == ["a"])
    // A whole number goes back as an int, as a row's default.
    #expect(size.fallback.setting == .int(13) && Setting<Double>("x", 1.5).fallback.setting == .double(1.5))
}
