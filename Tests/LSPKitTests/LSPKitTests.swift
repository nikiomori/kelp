import Core
import Foundation
import TestSupport
import Testing

@testable import LSPKit

@Test func framerHandlesSplitAndMultipleMessages() {
    let a = LSPFramer.frame(Data(#"{"a":1}"#.utf8)), b = LSPFramer.frame(Data(#"{"b":2}"#.utf8))
    var f = LSPFramer()
    let all = a + b
    #expect(f.append(all.prefix(10)).isEmpty)
    let out = f.append(all.dropFirst(10))
    #expect(out.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
}

@Test func framerSkipsBadLengths() {
    var f = LSPFramer()
    let bad = Data("Content-Length: -5\r\n\r\n".utf8) + LSPFramer.frame(Data(#"{"a":1}"#.utf8))
    #expect(f.append(bad).map { String(bytes: $0, encoding: .utf8) } == [#"{"a":1}"#])
}

@Test func requestsFailOnceTheServerExited() async throws {
    let c = try #require(LSPClient(argv: ["/usr/bin/true"], root: NSTemporaryDirectory()))
    #expect(try await waitFor(5) { !(c.isRunning) })
    #expect(!c.isRunning)
    await #expect(throws: RPCError.self) { _ = try await c.request("initialize", .null) }
}

@Test func silentServerTimesOut() async throws {
    let c = try #require(LSPClient(argv: ["/bin/sleep", "30"], root: NSTemporaryDirectory()))
    await #expect(throws: RPCError.self) { _ = try await c.request("initialize", .null, timeout: 0.2) }
    c.terminate()
}

/// A server's refusal is the server's: its code (-32602 here) isn't passed on as one of Kelp's own.
@Test func aServersErrorIsKelpsInternalOne() async throws {
    let reply = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad position"}}"#
    let script =
        "read -r line; sleep 0.2; printf 'Content-Length: \(reply.utf8.count)\\r\\n\\r\\n%s' '\(reply)'; sleep 5"
    let c = try #require(LSPClient(argv: ["/bin/sh", "-c", script], root: NSTemporaryDirectory()))
    await #expect(throws: RPCError.internalError("language server: bad position")) {
        _ = try await c.request("initialize", .null, timeout: 5)
    }
    c.terminate()
}

@Test func documentsAreSharedByTabs() throws {
    let c = try #require(LSPClient(argv: ["/bin/cat"], root: NSTemporaryDirectory()))
    let idle = Counter()
    c.onIdle = { idle.add() }
    c.open("/x.swift", text: "", languageId: "swift")
    c.open("/x.swift", text: "", languageId: "swift")
    c.close("/x.swift")
    #expect(idle.count == 0)
    c.close("/x.swift")
    #expect(idle.count == 1)
    c.close("/x.swift")   // not open: nothing to close
    c.terminate()
}

@Test func sourcekitDefinition() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString.prefix(6))").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = dir + "/main.swift"
    let text = "func greet() -> Int { 1 }\nlet x: String = greet()\n"
    try text.write(toFile: file, atomically: true, encoding: .utf8)
    guard let c = LSPClient(argv: ["xcrun", "sourcekit-lsp"], root: dir) else { return }
    try await c.initialize()
    c.open(file, text: text, languageId: "swift")
    let loc = try await c.definition(file, line: 2, column: 18)
    #expect(loc?.line == 1)
    c.shutdown()
}

final class Counter: @unchecked Sendable {
    private let l = NSLock()
    private var n = 0
    func add() {
        l.lock()
        n += 1
        l.unlock()
    }
    var count: Int {
        l.lock()
        defer { l.unlock() }
        return n
    }
}

@Test func symbolAroundALine() throws {
    func json(_ s: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
    func range(_ a: Int, _ b: Int) -> String {
        #"{"start":{"line":\#(a),"character":0},"end":{"line":\#(b),"character":0}}"#
    }
    // class TestParse (lines 1-9) > def test_empty (3-5) > local x (4); def helper (11-12)
    let tree = try json(
        #"""
        [{"name":"TestParse","kind":5,"range":\#(range(0, 8)),"children":[
           {"name":"test_empty","kind":6,"range":\#(range(2, 4)),"children":[{"name":"x","kind":13,"range":\#(range(3, 3))}]}]},
         {"name":"helper","kind":12,"range":\#(range(10, 11))}]
        """#)
    #expect(LSPClient.enclosingSymbol(tree, line: 4) == "test_empty")   // not the variable x
    #expect(LSPClient.enclosingSymbol(tree, line: 2) == "TestParse")
    #expect(LSPClient.enclosingSymbol(tree, line: 12) == "helper")
    #expect(LSPClient.enclosingSymbol(tree, line: 10) == nil)
    let flat = try json(#"[{"name":"TestFoo","kind":12,"location":{"uri":"file:///a.go","range":\#(range(4, 9))}}]"#)
    #expect(LSPClient.enclosingSymbol(flat, line: 6) == "TestFoo")
    #expect(LSPClient.enclosingSymbol(.null, line: 6) == nil)
}

/// A server that's alive but stopped answering is given up on, so the manager starts a new one; it used to be handed
/// out for good, each request waiting its full timeout.
@Test func aServerThatStopsAnsweringCountsAsExited() async throws {
    let c = try #require(LSPClient(argv: ["/bin/sleep", "30"], root: NSTemporaryDirectory()))
    for _ in 0..<LSPClient.timeoutsToGiveUp {
        await #expect(throws: RPCError.self) { _ = try await c.request("x", .null, timeout: 0.1) }
    }
    #expect(!c.isRunning)
}

/// Edits to a server that isn't reading wait as one copy per document, the newest: they used to queue a whole
/// document per keystroke.
@Test func editsWaitingForASlowServerKeepOnlyTheNewest() async throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString)").path
    let c = try #require(LSPClient(argv: ["/bin/sh", "-c", "sleep 1; cat > '\(out)'"], root: NSTemporaryDirectory()))
    c.open("/x.swift", text: "", languageId: "swift")
    let big = String(repeating: "x", count: 100_000)   // more than the pipe holds: later writes wait
    for i in 0..<50 { c.change("/x.swift", text: big + "\(i)") }
    func sent() -> String { (try? String(contentsOfFile: out, encoding: .utf8)) ?? "" }
    #expect(try await waitFor(10) { sent().contains("x49\"") })   // the last edit: nothing comes after it
    c.terminate()
    let sent = sent()
    #expect(sent.components(separatedBy: "didChange").count - 1 < 5)
    #expect(sent.contains("x49\""))   // the newest text (a short needle: contains on a 100 kB one crawls)
}

/// An edit made after a file was closed and opened again reaches the server after that didOpen: a queued edit from
/// before the close used to send the newest text early, in its place, and the server kept the reopened file's text.
@Test func anEditAfterReopeningComesAfterTheOpen() async throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString)").path
    let c = try #require(LSPClient(argv: ["/bin/sh", "-c", "sleep 1; cat > '\(out)'"], root: NSTemporaryDirectory()))
    let big = String(repeating: "x", count: 100_000)   // fills the pipe: the first edit's write waits
    c.open("/x.swift", text: "", languageId: "swift")
    c.change("/x.swift", text: big)
    c.change("/x.swift", text: "A")
    c.close("/x.swift")
    c.open("/x.swift", text: "B", languageId: "swift")
    c.change("/x.swift", text: "NEWEST")
    c.notify("kelpTestEnd", .null)   // after all of it: once the server has it, it has everything
    func sent() -> String { (try? String(contentsOfFile: out, encoding: .utf8)) ?? "" }
    #expect(try await waitFor(10) { sent().contains("kelpTestEnd") })
    c.terminate()
    let sent = sent()
    let lastOpen = try #require(sent.range(of: "didOpen", options: .backwards))
    let newest = try #require(sent.range(of: "NEWEST"))
    #expect(newest.lowerBound > lastOpen.lowerBound)
}

/// A server that ignores SIGTERM is gone once `terminateNow` returns: the daemon execs or exits right after, and the
/// SIGKILL `terminate` leaves for later would never come.
@Test func aServerThatIgnoresSIGTERMIsGoneBeforeTheDaemonMovesOn() async throws {
    let set = NSTemporaryDirectory() + "lsp-trap-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: set) }
    let c = try #require(
        LSPClient(
            argv: [
                "/bin/sh", "-c", "trap '' TERM; : > '\(set)'; i=0; while [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done"
            ],
            root: NSTemporaryDirectory()))
    let pid = try #require(c.pid)
    #expect(try await waitFor(10) { FileManager.default.fileExists(atPath: set) })   // the trap is set
    c.terminateNow()
    #expect(kill(pid, 0) != 0 || Subprocess.isZombie(pid))   // gone, or ended and waiting for its parent to reap it
}

@Test func workspaceSymbolsReadEitherShape() {
    let result: JSONValue = .array([
        .obj([
            "name": .string("Basket"), "kind": .int(23),
            "location": .obj([
                "uri": .string("file:///p/a.swift"),
                "range": .obj([
                    "start": .obj(["line": .int(4), "character": .int(0)]),
                    "end": .obj(["line": .int(4), "character": .int(6)])
                ])
            ])
        ]),
        .obj(["name": .string("total"), "kind": .int(12), "location": .obj(["uri": .string("file:///p/b.swift")])]),
        .obj(["name": .string("lost")])
    ])
    #expect(
        LSPClient.workspaceSymbols(result) == [
            CodeSymbol(name: "Basket", kind: "struct", line: 5, path: "/p/a.swift"),
            CodeSymbol(name: "total", kind: "function", line: 1, path: "/p/b.swift")
        ])
}
