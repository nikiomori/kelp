import Foundation
import Testing
import Core
import TestSupport
@testable import Daemon

/// A language server that answers initialize, definition, completion and documentSymbol, and writes what it heard
/// (started, each notification with the document's version, exit) to `log`.
private func fakeServer(in dir: String) throws -> (command: String, args: [String], log: String) {
    let script = dir + "/server.py", log = dir + "/server.log"
    try #"""
    import sys, json, os
    log = open(sys.argv[1], "a", buffering=1)
    log.write("start %d\n" % os.getpid())
    def read():
        head = b""
        while not head.endswith(b"\r\n\r\n"):
            c = sys.stdin.buffer.read(1)
            if not c: return None
            head += c
        n = int([h for h in head.decode().split("\r\n") if h.lower().startswith("content-length")][0].split(":")[1])
        return json.loads(sys.stdin.buffer.read(n))
    def send(o):
        b = json.dumps(o).encode()
        sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(b) + b); sys.stdout.buffer.flush()
    while True:
        m = read()
        if m is None: break
        meth = m.get("method")
        if "id" in m and meth:
            r = None
            if meth == "initialize": r = {"capabilities": {}}
            elif meth == "textDocument/definition":
                r = {"uri": "file:///tmp/defined.swift", "range": {"start": {"line": 4, "character": 2}, "end": {"line": 4, "character": 2}}}
            elif meth == "textDocument/completion": r = [{"label": "hello", "insertText": "hello()"}]
            elif meth == "textDocument/documentSymbol": r = []
            send({"jsonrpc": "2.0", "id": m["id"], "result": r})
        elif meth:
            doc = (m.get("params") or {}).get("textDocument") or {}
            log.write("%s %s\n" % (meth, doc.get("version", "")))
            if meth == "textDocument/didOpen":
                log.write("text %s %s\n" % (doc.get("uri"), doc.get("text")))
                if "problem" in doc.get("text", ""):
                    at = {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 6}}
                    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": doc.get("uri"), "diagnostics": [
                        {"range": at, "severity": 1, "message": "no such name"}, {"range": at, "severity": 2, "message": "unused"},
                        {"range": at, "severity": 4, "message": "a hint"}]}})
            if meth == "exit": break
    log.write("gone\n")
    """#.write(toFile: script, atomically: true, encoding: .utf8)
    return ("/usr/bin/python3", [script, log], log)
}

private func lines(_ log: String) -> [String] {
    ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

/// A file a tab opens through the daemon gets its server's answers: the daemon starts the server (the app no longer runs
/// one), gives it the file and every change in order, and asks it for definitions and completions.
@Test func aFileOpenedThroughTheDaemonGetsItsServersAnswers() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    let root = tmp().path, file = root + "/main.swift"
    let server = try fakeServer(in: root)
    try d.store.setUIState(LSPOpen.trustKey, .array([.string(root)]))
    _ = try await c.call(LSPOpen(root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: "let x = 1"))
    c.notify(LSPChange(root: root, path: file, text: "let x = 2"))
    #expect(try await c.call(LSPDefinition(root: root, path: file, line: 1, column: 5)) == CodeLocation(path: "/tmp/defined.swift", line: 5, column: 3))
    #expect(try await c.call(LSPCompletion(root: root, path: file, line: 1, column: 1)) == [CodeCompletion(label: "hello", insert: "hello()")])
    #expect(try await waitFor(5) { lines(server.log).contains("textDocument/didChange 2") })
    #expect(lines(server.log).filter { $0.hasPrefix("textDocument/") } == ["textDocument/didOpen 1", "textDocument/didChange 2"])
    // A second client of the same file shares the running server.
    let other = try client(d.root)
    _ = try await other.call(LSPOpen(root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: "let x = 2"))
    #expect(lines(server.log).filter { $0.hasPrefix("start") }.count == 1)
}

/// A project's language servers run its own code: the daemon starts none until the user trusted the project in Kelp's
/// window, whoever asks (an agent's `kelp` call included).
@Test func anUntrustedProjectStartsNoLanguageServer() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    let root = tmp().path, server = try fakeServer(in: root)
    do {
        _ = try await c.call(LSPOpen(root: root, path: root + "/main.swift", languageId: "swift", command: server.command, args: server.args, text: ""))
        Issue.record("opened in an untrusted project")
    } catch { #expect(LSPRefusal(error) == .untrusted) }
    do {
        try d.store.setUIState(LSPOpen.trustKey, .array([.string(root)]))
        _ = try await c.call(LSPOpen(root: root, path: root + "/main.swift", languageId: "swift", command: "no-such-server-\(UUID().uuidString.prefix(4))", text: ""))
        Issue.record("opened with a server that isn't there")
    } catch { #expect(LSPRefusal(error).map { if case .notInstalled = $0 { true } else { false } } == true) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(lines(server.log).isEmpty)
}

/// A server with no file open stops a while later: after its last close, and when the connection that opened the file
/// goes (the app quit, say).
@Test func aServerWithNoOpenFileStops() async throws {
    let (d, c, _) = try daemon(lspDelays: (retry: 30, idle: 0.3)); defer { d.stop() }
    let root = tmp().path, file = root + "/main.swift", server = try fakeServer(in: root)
    try d.store.setUIState(LSPOpen.trustKey, .array([.string(root)]))
    func open(_ c: RPCClient) async throws {
        _ = try await c.call(LSPOpen(root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: ""))
        #expect(try await c.call(LSPCompletion(root: root, path: file, line: 1, column: 1)).count == 1)   // running
    }
    /// The servers started so far that still run.
    func running() -> [Int32] {
        lines(server.log).compactMap { $0.hasPrefix("start ") ? Int32($0.dropFirst(6)) : nil }.filter { kill($0, 0) == 0 }
    }
    try await open(c)
    _ = try await c.call(LSPClose(root: root, path: file))
    #expect(try await waitFor(5) { running().isEmpty })
    // Opened again by a connection that then goes: closed with it, and stopped.
    let other = try client(d.root)
    try await open(other)
    #expect(running().count == 1 && lines(server.log).filter { $0.hasPrefix("start") }.count == 2)
    other.close()
    #expect(try await waitFor(5) { running().isEmpty })
}

/// A server that died starts again on the next open, and gets every file open for it as the app last sent it (unsaved
/// edits too), not as it is on disk.
@Test func aRestartedServerGetsTheOpenFilesAsLastSent() async throws {
    let (d, c, _) = try daemon(lspDelays: (retry: 0, idle: 60)); defer { d.stop() }
    let root = tmp().path, a = root + "/a.swift", b = root + "/b.swift", server = try fakeServer(in: root)
    try "on disk".write(toFile: a, atomically: true, encoding: .utf8)
    try d.store.setUIState(LSPOpen.trustKey, .array([.string(root)]))
    func open(_ path: String, _ text: String) async throws {
        _ = try await c.call(LSPOpen(root: root, path: path, languageId: "swift", command: server.command, args: server.args, text: text))
    }
    try await open(a, "on disk")
    try await open(b, "b")
    c.notify(LSPChange(root: root, path: a, text: "unsaved"))
    #expect(try await waitFor(5) { lines(server.log).contains("textDocument/didChange 2") })
    let first = try #require(lines(server.log).first { $0.hasPrefix("start ") }.flatMap { Int32($0.dropFirst(6)) })
    kill(first, SIGKILL)
    #expect(try await waitFor(5) { await d.lsp.client(root, b) == nil })   // its client saw it go
    try await open(b, "b")
    let unsaved = "text \(URL(fileURLWithPath: a).absoluteString) unsaved"
    #expect(try await waitFor(5) { lines(server.log).filter { $0.hasPrefix("start ") }.count == 2 && lines(server.log).contains(unsaved) })
}

/// What a server says is wrong reaches the daemon's reading of the file, errors and warnings without the hints, and goes with
/// the file's tab.
@Test func aServersProblemsAreKeptForTheFile() async throws {
    let (d, c, _) = try daemon(); defer { d.stop() }
    let root = tmp().path, file = root + "/main.swift", server = try fakeServer(in: root)
    try await c.call(StateSet(key: LSPOpen.trustKey, value: .array([.string(root)])))
    try await c.call(LSPOpen(root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: "a problem\n  name\n"))
    #expect(try await waitFor(10) { try await c.call(LSPProblems(path: file)).count == 2 })
    let found = try await c.call(LSPProblems(path: file))
    #expect(found.map(\.isError) == [true, false])
    #expect(found[0] == CodeProblem(line: 1, column: 2, endLine: 1, endColumn: 6, isError: true, message: "no such name"))
    try await c.call(LSPClose(root: root, path: file))
    #expect(try await c.call(LSPProblems(path: file)).isEmpty)
}
