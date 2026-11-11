import Core
import Foundation
import TestSupport
import Testing

@testable import Daemon
@testable import LSPKit

/// A language server that answers initialize, definition, completion, symbols, hover, signatures, references, rename and
/// code actions (the project's symbols in the file opened last), and writes what it heard (started, each notification
/// with the document's version, exit) to `log`.
private func fakeServer(in dir: String) throws -> (command: String, args: [String], log: String) {
    let script = dir + "/server.py", log = dir + "/server.log"
    try #"""
    import sys, json, os
    log = open(sys.argv[1], "a", buffering=1)
    log.write("start %d\n" % os.getpid())
    opened = [None]
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
            uri = ((m.get("params") or {}).get("textDocument") or {}).get("uri")
            def at(l, c): return {"start": {"line": l, "character": c}, "end": {"line": l, "character": c + 5}}
            edit = {"changes": {uri: [{"range": at(0, 4), "newText": (m.get("params") or {}).get("newName", "fixed")}]}}
            if meth == "initialize": r = {"capabilities": {}}
            elif meth == "textDocument/definition":
                r = {"uri": "file:///tmp/defined.swift", "range": {"start": {"line": 4, "character": 2}, "end": {"line": 4, "character": 2}}}
            elif meth == "textDocument/completion": r = [{"label": "hello", "insertText": "hello()"}]
            elif meth == "textDocument/documentSymbol":
                r = [{"name": "greet", "kind": 12, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 2, "character": 1}},
                      "selectionRange": at(0, 5), "children": [{"name": "word", "kind": 13, "range": at(1, 8), "selectionRange": at(1, 8)}]}]
            elif meth == "textDocument/hover": r = {"contents": {"kind": "markdown", "value": "Says hello"}}
            elif meth == "textDocument/signatureHelp":
                r = {"signatures": [{"label": "greet(name: String)", "parameters": [{"label": "name: String"}]}], "activeParameter": 0}
            elif meth == "textDocument/references":
                r = [{"uri": uri, "range": at(1, 8)}, {"uri": "file:///usr/lib/swift/Core.swift", "range": at(9, 0)}]
            elif meth == "textDocument/rename": r = edit
            elif meth == "textDocument/codeAction": r = [{"title": "Fix it", "edit": edit}, {"title": "Run", "command": {"command": "x"}}]
            elif meth == "workspace/symbol":
                r = [{"name": "greet", "kind": 12, "location": {"uri": opened[0], "range": at(0, 5)}},
                     {"name": "print", "kind": 12, "location": {"uri": "file:///usr/lib/swift/Core.swift", "range": at(9, 0)}}]
            send({"jsonrpc": "2.0", "id": m["id"], "result": r})
        elif meth:
            doc = (m.get("params") or {}).get("textDocument") or {}
            log.write("%s %s\n" % (meth, doc.get("version", "")))
            if meth == "textDocument/didOpen":
                opened[:] = [doc.get("uri")]
                log.write("text %s %s\n" % (doc.get("uri"), doc.get("text")))
                if "problem" in doc.get("text", ""):
                    at = {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 6}}
                    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": doc.get("uri"), "diagnostics": [
                        {"range": at, "severity": 1, "message": "no such name"}, {"range": at, "severity": 2, "message": "unused"},
                        {"range": at, "severity": 4, "message": "a hint"}]}})
                    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": "file:///tmp/elsewhere.swift",
                        "diagnostics": [{"range": at, "severity": 1, "message": "not open"}]}})
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
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = tmp().path, file = root + "/main.swift"
    let server = try fakeServer(in: root)
    try d.store.setDaemonState(LSPOpen.trustKey, JSONValue.array([.string(root)]))
    _ = try await c.call(
        LSPOpen(
            root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: "let x = 1"))
    c.notify(LSPChange(root: root, path: file, text: "let x = 2"))
    #expect(
        try await c.call(LSPDefinition(root: root, path: file, line: 1, column: 5))
            == CodeLocation(path: "/tmp/defined.swift", line: 5, column: 3))
    #expect(
        try await c.call(LSPCompletion(root: root, path: file, line: 1, column: 1)) == [
            CodeCompletion(label: "hello", insert: "hello()")
        ])
    #expect(try await waitFor(5) { lines(server.log).contains("textDocument/didChange 2") })
    #expect(
        lines(server.log).filter { $0.hasPrefix("textDocument/") } == [
            "textDocument/didOpen 1", "textDocument/didChange 2"
        ])
    // A second client of the same file shares the running server.
    let other = try client(d.root)
    _ = try await other.call(
        LSPOpen(
            root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: "let x = 2"))
    #expect(lines(server.log).filter { $0.hasPrefix("start") }.count == 1)
}

/// What the editor asks a server about a place, read back as Kelp's own values: the symbol around a line and the file's
/// symbols, hover text, a signature with its parameter, references and the project's symbols (a toolchain's left out),
/// and a rename's and a quick fix's edits (an action that only runs a command left out).
@Test func aServersAnswersAboutAPlaceComeBackAsKelpsValues() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = tmp().path, file = root + "/main.swift", server = try fakeServer(in: root)
    let text = "func greet() {\n    let word = 1\n}\n"
    try text.write(toFile: file, atomically: true, encoding: .utf8)
    try d.store.setDaemonState(LSPOpen.trustKey, JSONValue.array([.string(root)]))
    _ = try await c.call(
        LSPOpen(root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: text))
    #expect(try await c.call(LSPSymbol(root: root, path: file, line: 2)) == "greet")
    #expect(
        try await c.call(LSPSymbols(root: root, path: file)) == [
            CodeSymbol(name: "greet", kind: "function", line: 1), CodeSymbol(name: "word", kind: "variable", line: 2)
        ])
    #expect(try await c.call(LSPHover(root: root, path: file, line: 1, column: 6)) == "Says hello")
    #expect(
        try await c.call(LSPSignature(root: root, path: file, line: 1, column: 12))
            == CodeSignature(label: "greet(name: String)", activeStart: 6, activeEnd: 18))
    #expect(
        try await c.call(LSPReferences(root: root, path: file, line: 1, column: 6)) == [
            SearchMatch(path: "main.swift", line: 2, text: "let word = 1")
        ])
    #expect(
        try await c.call(LSPWorkspaceSymbols(root: root, path: file, query: "gr")) == [
            CodeSymbol(name: "greet", kind: "function", line: 1, path: file)
        ])
    let renamed = CodeFileEdit(path: file, edits: [CodeEdit(line: 0, column: 4, endLine: 0, endColumn: 9, text: "hi")])
    #expect(try await c.call(LSPRename(root: root, path: file, line: 1, column: 6, name: "hi")) == [renamed])
    let fixed = CodeFileEdit(path: file, edits: [CodeEdit(line: 0, column: 4, endLine: 0, endColumn: 9, text: "fixed")])
    #expect(
        try await c.call(LSPActions(root: root, path: file, line: 1, column: 6)) == [
            CodeAction(title: "Fix it", files: [fixed])
        ])
}

/// A project's language servers run its own code: the daemon starts none until the user trusted the project in Kelp's
/// window, whoever asks (an agent's `kelp` call included).
@Test func anUntrustedProjectStartsNoLanguageServer() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = tmp().path, server = try fakeServer(in: root)
    do {
        _ = try await c.call(
            LSPOpen(
                root: root, path: root + "/main.swift", languageId: "swift", command: server.command, args: server.args,
                text: ""))
        Issue.record("opened in an untrusted project")
    } catch { #expect(LSPRefusal(error) == .untrusted) }
    do {
        try d.store.setDaemonState(LSPOpen.trustKey, JSONValue.array([.string(root)]))
        _ = try await c.call(
            LSPOpen(
                root: root, path: root + "/main.swift", languageId: "swift",
                command: "no-such-server-\(UUID().uuidString.prefix(4))", text: ""))
        Issue.record("opened with a server that isn't there")
    } catch { #expect(LSPRefusal(error).map { if case .notInstalled = $0 { true } else { false } } == true) }
    // A server starts only for a file the daemon took as open, and neither was: nothing answers for it.
    #expect(try await c.call(LSPCompletion(root: root, path: root + "/main.swift", line: 1, column: 1)).isEmpty)
    #expect(lines(server.log).isEmpty)
}

/// A server with no file open stops a while later: after its last close, and when the connection that opened the file
/// goes (the app quit, say). No idle time here: it stops as soon as nothing is open, and the test waits for its end.
@Test func aServerWithNoOpenFileStops() async throws {
    let (d, c, _) = try daemon(lspDelays: (retry: 30, idle: 0))
    defer { d.stop() }
    let root = tmp().path, file = root + "/main.swift", server = try fakeServer(in: root)
    try d.store.setDaemonState(LSPOpen.trustKey, JSONValue.array([.string(root)]))
    func open(_ c: RPCClient) async throws {
        _ = try await c.call(
            LSPOpen(root: root, path: file, languageId: "swift", command: server.command, args: server.args, text: ""))
        #expect(try await c.call(LSPCompletion(root: root, path: file, line: 1, column: 1)).count == 1)   // running
    }
    /// The servers started so far that still run.
    func running() -> [Int32] {
        lines(server.log).compactMap { $0.hasPrefix("start ") ? Int32($0.dropFirst(6)) : nil }.filter {
            kill($0, 0) == 0
        }
    }
    try await open(c)
    _ = try await c.call(LSPClose(root: root, path: file))
    #expect(try await waitFor(15) { running().isEmpty })
    // Opened again by a connection that then goes: closed with it, and stopped.
    let other = try client(d.root)
    try await open(other)
    #expect(running().count == 1 && lines(server.log).filter { $0.hasPrefix("start") }.count == 2)
    other.close()
    #expect(try await waitFor(15) { running().isEmpty })
}

/// A server that died starts again on the next open, and gets every file open for it as the app last sent it (unsaved
/// edits too), not as it is on disk.
@Test func aRestartedServerGetsTheOpenFilesAsLastSent() async throws {
    let (d, c, _) = try daemon(lspDelays: (retry: 0, idle: 60))
    defer { d.stop() }
    let root = tmp().path, a = root + "/a.swift", b = root + "/b.swift", server = try fakeServer(in: root)
    try "on disk".write(toFile: a, atomically: true, encoding: .utf8)
    try d.store.setDaemonState(LSPOpen.trustKey, JSONValue.array([.string(root)]))
    func open(_ path: String, _ text: String) async throws {
        _ = try await c.call(
            LSPOpen(root: root, path: path, languageId: "swift", command: server.command, args: server.args, text: text)
        )
    }
    try await open(a, "on disk")
    try await open(b, "b")
    c.notify(LSPChange(root: root, path: a, text: "unsaved"))
    #expect(try await waitFor(5) { lines(server.log).contains("textDocument/didChange 2") })
    let first = try #require(lines(server.log).first { $0.hasPrefix("start ") }.flatMap { Int32($0.dropFirst(6)) })
    kill(first, SIGKILL)
    #expect(try await waitFor(5) { await d.lsp.clients(root, b).first == nil })   // its client saw it go
    try await open(b, "b")
    let unsaved = "text \(URL(fileURLWithPath: a).absoluteString) unsaved"
    #expect(
        try await waitFor(5) {
            lines(server.log).filter { $0.hasPrefix("start ") }.count == 2 && lines(server.log).contains(unsaved)
        })
}

/// What a server says is wrong reaches the daemon's reading of the file, errors and warnings without the hints, and goes with
/// the file's tab.
@Test func aServersProblemsAreKeptForTheFile() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = tmp().path, file = root + "/main.swift", server = try fakeServer(in: root)
    _ = try await c.call(StateSet(key: LSPOpen.trustKey, value: .array([.string(root)])))
    _ = try await c.call(
        LSPOpen(
            root: root, path: file, languageId: "swift", command: server.command, args: server.args,
            text: "a problem\n  name\n"))
    #expect(try await waitFor(10) { try await c.call(LSPProblems(path: file)).count == 2 })
    let found = try await c.call(LSPProblems(path: file))
    #expect(found.map(\.isError) == [true, false])
    #expect(
        found[0] == CodeProblem(line: 1, column: 2, endLine: 1, endColumn: 6, isError: true, message: "no such name"))
    #expect(try await c.call(LSPProblems(path: "/tmp/elsewhere.swift")).isEmpty)   // no tab has it: not kept for the server's life
    // Open in another connection's tab too: closed in one, its problems stay for the other.
    let other = try client(d.root)
    _ = try await other.call(
        LSPOpen(
            root: root, path: file, languageId: "swift", command: server.command, args: server.args,
            text: "a problem\n  name\n"))
    _ = try await c.call(LSPClose(root: root, path: file))
    #expect(try await c.call(LSPProblems(path: file)).count == 2)
    _ = try await other.call(LSPClose(root: root, path: file))
    #expect(try await c.call(LSPProblems(path: file)).isEmpty)
}

@Test func aServersSymbolsComeFlatAndTopToBottom() {
    let result: JSONValue = .array([
        .obj([
            "name": .string("Type"), "kind": .int(23),
            "selectionRange": .obj(["start": .obj(["line": .int(4), "character": .int(0)])]),
            "children": .array([
                .obj([
                    "name": .string("run"), "kind": .int(6),
                    "selectionRange": .obj(["start": .obj(["line": .int(6), "character": .int(2)])])
                ])
            ])
        ]),
        .obj([
            "name": .string("top"), "kind": .int(12),
            "location": .obj(["range": .obj(["start": .obj(["line": .int(0), "character": .int(0)])])])
        ])
    ])
    #expect(LSPClient.symbols(result).map(\.name) == ["top", "Type", "run"])
    #expect(LSPClient.symbols(result).map(\.kind) == ["function", "struct", "method"])
    #expect(LSPClient.symbols(result).map(\.line) == [1, 5, 7])
}

@Test func aHoverComesInAnyOfTheProtocolsShapes() {
    #expect(
        LSPClient.hoverText(.obj(["contents": .obj(["kind": .string("markdown"), "value": .string("**x**")])]))
            == "**x**")
    #expect(LSPClient.hoverText(.obj(["contents": .string("plain")])) == "plain")
    #expect(
        LSPClient.hoverText(
            .obj(["contents": .array([.string("a"), .obj(["language": .string("swift"), "value": .string("let x")])])]))
            == "a\n\n```swift\nlet x\n```")
    #expect(LSPClient.hoverText(.obj(["contents": .string("  ")])) == nil)
    #expect(LSPClient.hoverText(.null) == nil)
}

@Test func theActiveArgumentIsFoundByNameOrOffsets() {
    func help(_ param: JSONValue, active: Int = 1) -> JSONValue {
        .obj([
            "activeSignature": .int(0), "activeParameter": .int(active),
            "signatures": .array([
                .obj([
                    "label": .string("f(a: Int, b: Int)"),
                    "parameters": .array([.obj(["label": .string("a: Int")]), .obj(["label": param])])
                ])
            ])
        ])
    }
    #expect(
        LSPClient.signature(help(.string("b: Int")))
            == CodeSignature(label: "f(a: Int, b: Int)", activeStart: 10, activeEnd: 16))
    #expect(LSPClient.signature(help(.array([.int(10), .int(16)])))?.activeEnd == 16)
    #expect(LSPClient.signature(help(.string("x"), active: 5))?.activeStart == nil)
    #expect(LSPClient.signature(.obj(["signatures": .array([])])) == nil)
}

@Test func aServersCompletionsKeepTheirEditsAndOrder() {
    let at: JSONValue = .obj([
        "start": .obj(["line": .int(1), "character": .int(2)]), "end": .obj(["line": .int(1), "character": .int(4)])
    ])
    let found = LSPClient.completions(
        .obj([
            "items": .array([
                .obj([
                    "label": .string("b"), "sortText": .string("2"), "kind": .int(2), "insertTextFormat": .int(2),
                    "insertText": .string("b($1)"),
                    "documentation": .obj(["kind": .string("markdown"), "value": .string("doc")])
                ]),
                .obj([
                    "label": .string("a"), "sortText": .string("1"),
                    "textEdit": .obj(["range": at, "newText": .string("aa")]),
                    "additionalTextEdits": .array([.obj(["range": at, "newText": .string("import a\n")])])
                ])
            ])
        ]))
    #expect(found.map(\.label) == ["a", "b"])
    #expect(found[0].insert == "aa" && found[0].edit?.column == 2 && found[0].more?.first?.text == "import a\n")
    #expect(found[1].kind == "method" && found[1].snippet == true && found[1].documentation == "doc")
}

@Test func aWorkspaceEditComesInEitherShape() {
    let edit: JSONValue = .obj([
        "range": .obj([
            "start": .obj(["line": .int(0), "character": .int(1)]),
            "end": .obj(["line": .int(0), "character": .int(3)])
        ]),
        "newText": .string("x")
    ])
    let changes = LSPClient.fileEdits(
        .obj(["changes": .obj(["file:///a.swift": .array([edit]), "file:///b.swift": .array([])])]))
    #expect(
        changes == [
            CodeFileEdit(path: "/a.swift", edits: [CodeEdit(line: 0, column: 1, endLine: 0, endColumn: 3, text: "x")])
        ])
    let doc = LSPClient.fileEdits(
        .obj([
            "documentChanges": .array([
                .obj(["textDocument": .obj(["uri": .string("file:///c.swift")]), "edits": .array([edit])])
            ])
        ]))
    #expect(doc.map(\.path) == ["/c.swift"])
}

/// A server beside a file's own, as a linter is: named `name`, it says it can do `can`, answers completion, hover and
/// code actions with its name, reports one problem on line `line` of each file opened, and writes to `log` the options
/// it started with and what it got when it asked for its settings.
private func fakeLinter(_ name: String, can: String, line: Int, in dir: String) throws -> (args: [String], log: String)
{
    let script = dir + "/\(name).py", log = dir + "/\(name).log"
    try #"""
    import sys, json
    name, can, line, log = sys.argv[1], json.loads(sys.argv[2]), int(sys.argv[3]), open(sys.argv[4], "a", buffering=1)
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
        meth, params = m.get("method"), m.get("params") or {}
        uri = (params.get("textDocument") or {}).get("uri")
        at = {"start": {"line": line, "character": 0}, "end": {"line": line, "character": 1}}
        if "id" in m and meth:
            r = None
            if meth == "initialize":
                log.write("options %s\n" % json.dumps(params.get("initializationOptions"), sort_keys=True))
                log.write("asks %s\n" % json.dumps(params["capabilities"]["workspace"].get("configuration")))
                r = {"capabilities": can}
            elif meth == "textDocument/completion": r = [{"label": name}]
            elif meth == "textDocument/hover": r = {"contents": name}
            elif meth == "textDocument/codeAction":
                r = [{"title": "fix " + name, "edit": {"changes": {uri: [{"range": at, "newText": name}]}}}]
            send({"jsonrpc": "2.0", "id": m["id"], "result": r})
        elif meth == "initialized":
            send({"jsonrpc": "2.0", "id": "cfg", "method": "workspace/configuration",
                  "params": {"items": [{"section": "lint.select"}, {"section": "nope"}, {}]}})
        elif meth == "workspace/didChangeConfiguration": log.write("pushed %s\n" % json.dumps(params, sort_keys=True))
        elif meth == "textDocument/didOpen":
            send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": [
                {"range": at, "severity": 2, "message": "from " + name}]}})
        elif meth == "exit": break
        elif m.get("id") == "cfg": log.write("settings %s\n" % json.dumps(m.get("result"), sort_keys=True))
    """#.write(toFile: script, atomically: true, encoding: .utf8)
    return ([script, name, can, String(line), log], log)
}

/// A file of two servers (its language's and a linter's) is open at both: each one's problems show, top to bottom, a
/// question goes to the first in their order that said it can answer (not to the one opened first), fixes come from
/// both, and a tab closed closes it at both.
@Test func aFileOfTwoServersGetsBothsProblemsAndFixes() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = tmp().path, file = root + "/main.py"
    let own = try fakeLinter("own", can: #"{"completionProvider": {}, "codeActionProvider": true}"#, line: 3, in: root)
    let lint = try fakeLinter("lint", can: #"{"hoverProvider": true, "codeActionProvider": true}"#, line: 1, in: root)
    try d.store.setDaemonState(LSPOpen.trustKey, JSONValue.array([.string(root)]))
    func open(_ args: [String], order: Int) async throws {
        _ = try await c.call(
            LSPOpen(
                root: root, path: file, languageId: "python", command: "/usr/bin/python3", args: args, text: "x",
                rank: order))
    }
    try await open(lint.args, order: 1)
    try await open(own.args, order: 0)
    #expect(try await c.call(LSPCompletion(root: root, path: file, line: 1, column: 1)).map(\.label) == ["own"])
    #expect(try await c.call(LSPHover(root: root, path: file, line: 1, column: 1)) == "lint")   // the first can't
    #expect(
        try await c.call(LSPActions(root: root, path: file, line: 1, column: 1)).map(\.title) == ["fix own", "fix lint"]
    )
    #expect(
        try await waitFor(5) {
            (try? await c.call(LSPProblems(path: file)))?.map(\.message) == ["from lint", "from own"]
        })
    #expect(lines(own.log).contains("asks null"))   // no settings given: it isn't told to ask for any
    _ = try await c.call(LSPClose(root: root, path: file))
    #expect(try await c.call(LSPProblems(path: file)).isEmpty)
    #expect(try await c.call(LSPCompletion(root: root, path: file, line: 1, column: 1)).isEmpty)
}

/// A server's `options` reach it as it starts, and its `settings` when it's up and whenever it asks: the part each
/// dotted section names, all of them for no section, null for one that isn't there.
@Test func aServerGetsItsOptionsAndSettings() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let root = tmp().path, file = root + "/main.py", lint = try fakeLinter("lint", can: "{}", line: 0, in: root)
    try d.store.setDaemonState(LSPOpen.trustKey, JSONValue.array([.string(root)]))
    let settings = JSONValue.object(["lint": .object(["select": .array([.string("E")])])])
    _ = try await c.call(
        LSPOpen(
            root: root, path: file, languageId: "python", command: "/usr/bin/python3", args: lint.args, text: "x",
            options: .object(["fast": .bool(true)]), settings: settings))
    #expect(try await waitFor(5) { lines(lint.log).contains { $0.hasPrefix("settings") } })
    #expect(
        lines(lint.log) == [
            #"options {"fast": true}"#, "asks true", #"pushed {"settings": {"lint": {"select": ["E"]}}}"#,
            #"settings [["E"], null, {"lint": {"select": ["E"]}}]"#
        ])
}
