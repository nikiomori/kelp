import Core
import Foundation
import os

/// `Content-Length` framed JSON-RPC, as LSP speaks over stdio.
public struct LSPFramer: Sendable {
    private var buf = Data()
    static let maxBody = 256 << 20
    public init() {}
    public static func frame(_ body: Data) -> Data { Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body }
    public mutating func append(_ d: Data) -> [Data] {
        buf.append(d)
        var out: [Data] = []
        let sep = Data("\r\n\r\n".utf8)
        while let r = buf.range(of: sep) {
            let header = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
            // A missing, negative or absurd length is a broken header: skip it rather than trap or wait forever.
            guard
                let len = header.split(separator: "\r\n").compactMap({ l -> Int? in
                    let p = l.split(separator: ":", maxSplits: 1)
                    return p.count == 2 && p[0].lowercased() == "content-length"
                        ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
                }).first, (0...Self.maxBody).contains(len)
            else {
                buf.removeSubrange(buf.startIndex..<r.upperBound)
                continue
            }
            guard buf.distance(from: r.upperBound, to: buf.endIndex) >= len else { break }
            let end = buf.index(r.upperBound, offsetBy: len)
            out.append(Data(buf[r.upperBound..<end]))
            buf.removeSubrange(buf.startIndex..<end)
        }
        return out
    }
}

/// One language server process for one workspace root. Once the process has exited every request fails at once
/// (the manager starts a new client); a request the server never answers fails after its timeout.
public final class LSPClient: @unchecked Sendable {   // Process and Pipe aren't Sendable; everything that changes is in `state`
    private let proc = Process()
    private let input = Pipe(), output = Pipe()
    /// stdin writes, in order and off the caller's thread: a server that stops reading must not block the UI.
    private let writes = DispatchQueue(label: "kelp.lsp.stdin")
    private struct State {
        var diagnostics: [String: [JSONValue]] = [:]   // as the server said them: a code action is asked with them
        var nextID = 1
        var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
        var versions: [String: Int] = [:]
        var opened: [String: Int] = [:]   // path -> how many tabs have it open (didOpen once, didClose after the last)
        var exited = false
        /// Requests in a row that got no answer in time: a server alive but hung (it stopped reading) is given up on.
        var timeouts = 0
        /// The latest text of each document whose didChange waits on the write queue: one write sends the newest, so a
        /// server that reads slowly gets one copy per document, not one per keystroke.
        /// Each with the number of the write that sends it: a write queued before the document was closed finds a
        /// newer number (or none) and sends nothing, so it can't carry text from after a reopen ahead of that didOpen.
        var changes: [String: (write: Int, params: JSONValue)] = [:]
        var nextWrite = 0
        var onIdle: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public let root: String
    private let onProblems: (@Sendable (String, [CodeProblem]) -> Void)?
    /// The last open document was closed.
    public var onIdle: (@Sendable () -> Void)? {
        get { state.withLock { $0.onIdle } }
        set { state.withLock { $0.onIdle = newValue } }
    }

    /// `argv[0]` is looked up on the login-shell PATH, which the server gets too (npm servers need `node`).
    /// `onProblems`: a file's errors and warnings, each time the server says them.
    public init?(argv: [String], root: String, onProblems: (@Sendable (_ path: String, [CodeProblem]) -> Void)? = nil) {
        guard let cmd = argv.first, let exe = try? LoginPath.resolve(cmd) else { return nil }
        self.root = root
        self.onProblems = onProblems
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginPath.value
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)   // a server that died fails the write, not the app
        // Weak: the reader must not keep the client (and so the server) alive; deinit terminates the server, which ends the loop.
        // read(2), not FileHandle.availableData, which raises on a read error and would take the daemon down.
        // The reader holds the read end: let go of with the client, its number could be someone else's by the next read.
        let reading = output.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var framer = LSPFramer(), buf = [UInt8](repeating: 0, count: 1 << 16)
            withExtendedLifetime(reading) {
                while case let n = read(reading.fileDescriptor, &buf, buf.count), n > 0 || (n < 0 && errno == EINTR) {
                    guard n > 0 else { continue }
                    for body in framer.append(Data(buf[0..<n])) { self?.handle(body) }
                }
            }
            self?.fail(RPCError.internalError("language server exited"))
        }
    }

    deinit {
        terminate()
        state.withLock { $0.pending }.values.forEach {
            $0.resume(throwing: RPCError.internalError("language server stopped"))
        }
    }

    /// The server and what it started (tsserver's workers…), SIGKILL for what's left after 2 s.
    public func terminate() { if proc.isRunning { Subprocess.stopTree(proc.processIdentifier) } }
    /// `terminate`, done before it returns (what ignores SIGTERM gets SIGKILL): for a daemon about to exit or exec.
    public func terminateNow() { if proc.isRunning { Subprocess.stopTreeNow(proc.processIdentifier) } }
    /// The server's process id, while it runs.
    public var pid: pid_t? { proc.isRunning ? proc.processIdentifier : nil }
    /// After this many requests in a row go unanswered the server counts as exited (the manager starts a new one).
    static let timeoutsToGiveUp = 3
    public var isRunning: Bool { state.withLock { !$0.exited } }

    private func fail(_ e: RPCError) {
        let all = state.withLock { s in
            defer { s.pending = [:] }
            s.exited = true
            return s.pending
        }
        all.values.forEach { $0.resume(throwing: e) }
    }

    /// Decoded as plain JSON: ids may be numbers or strings.
    private func handle(_ body: Data) {
        guard let m = try? JSONDecoder().decode(JSONValue.self, from: body) else { return }
        let id = m["id"].flatMap { $0 == .null ? nil : $0 }
        if let method = m["method"]?.string {   // a request (workspace/configuration) gets null; of the notifications, only diagnostics count
            if let id { send(["jsonrpc": "2.0", "id": id, "result": .null]) }
            if method == "textDocument/publishDiagnostics", let p = m["params"], let (path, found) = Self.problems(p) {
                state.withLock { $0.diagnostics[path] = p["diagnostics"]?.array }
                onProblems?(path, found)
            }
            return
        }
        guard let id = id?.int else { return }
        let c = state.withLock { s in
            s.timeouts = 0
            return s.pending.removeValue(forKey: id)
        }
        if let e = m["error"], e != .null {
            c?.resume(
                throwing: RPCError(
                    code: e["code"]?.int ?? -32603, message: e["message"]?.string ?? "language server error"))
        } else {
            c?.resume(returning: m["result"] ?? .null)
        }
    }

    /// Encoded on the write queue too: didChange sends the whole document, and the caller is usually the main thread.
    private func send(_ o: [String: JSONValue]) {
        let h = input.fileHandleForWriting   // not self: a blocked write must not keep the client alive
        writes.async {
            guard let d = try? JSONEncoder().encode(JSONValue.object(o)) else { return }
            try? h.write(contentsOf: LSPFramer.frame(d))
        }
    }

    public func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { c in
            let id = state.withLock { s -> Int? in
                guard !s.exited else { return nil }
                defer { s.nextID += 1 }
                s.pending[s.nextID] = c
                return s.nextID
            }
            guard let id else {
                c.resume(throwing: RPCError.internalError("language server exited"))
                return
            }
            send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let (c, hung) = state.withLock { s in
                    let c = s.pending.removeValue(forKey: id)
                    if c != nil { s.timeouts += 1 }
                    return (c, s.timeouts >= Self.timeoutsToGiveUp)
                }
                c?.resume(
                    throwing: RPCError.internalError(
                        "no answer to \(method) from the language server in \(Int(timeout)) s"))
                if hung {
                    fail(RPCError.internalError("the language server stopped answering"))
                    terminate()
                }
            }
        }
    }
    public func notify(_ method: String, _ params: JSONValue) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    public func initialize() async throws {
        let uri = URL(fileURLWithPath: root).absoluteString
        _ = try await request(
            "initialize",
            .obj([
                "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)), "rootUri": .string(uri),
                "workspaceFolders": .array([
                    .obj(["uri": .string(uri), "name": .string((root as NSString).lastPathComponent)])
                ]),
                "capabilities": .obj([
                    "workspace": .obj(["symbol": .obj([:])]),
                    "textDocument": .obj([
                        "definition": .obj([:]), "references": .obj([:]), "rename": .obj([:]),
                        "codeAction": .obj([
                            "codeActionLiteralSupport": .obj([
                                "codeActionKind": .obj([
                                    "valueSet": .array(["quickfix", "refactor", "source"].map(JSONValue.string))
                                ])
                            ])
                        ]),
                        "hover": .obj(["contentFormat": .array([.string("markdown"), .string("plaintext")])]),
                        "signatureHelp": .obj([
                            "signatureInformation": .obj([
                                "parameterInformation": .obj(["labelOffsetSupport": true])
                            ])
                        ]),
                        "completion": .obj([
                            "completionItem": .obj([
                                "snippetSupport": true,
                                "documentationFormat": .array([.string("plaintext"), .string("markdown")])
                            ])
                        ]),
                        "documentSymbol": .obj(["hierarchicalDocumentSymbolSupport": true])
                    ])
                ])
            ]))
        notify("initialized", .obj([:]))
    }

    /// `publishDiagnostics`' params: errors and warnings, not the hints a server has for every other line.
    static func problems(_ params: JSONValue) -> (path: String, found: [CodeProblem])? {
        guard let uri = params["uri"]?.string, let path = URL(string: uri)?.path else { return nil }
        let found = (params["diagnostics"]?.array ?? []).compactMap { d -> CodeProblem? in
            guard let start = d["range"]?["start"], let end = d["range"]?["end"], let l = start["line"]?.int,
                let c = start["character"]?.int,
                let el = end["line"]?.int, let ec = end["character"]?.int, let message = d["message"]?.string
            else { return nil }
            let severity = d["severity"]?.int ?? 1
            return severity <= 2
                ? CodeProblem(line: l, column: c, endLine: el, endColumn: ec, isError: severity == 1, message: message)
                : nil
        }
        return (path, found)
    }

    static func uri(_ path: String) -> JSONValue { .string(URL(fileURLWithPath: path).absoluteString) }
    static func pos(_ line: Int, _ col: Int) -> JSONValue {
        .obj(["line": .int(line - 1), "character": .int(col - 1)])
    }

    /// One server can serve several languages (typescript, javascriptreact…), so each file says which it is.
    /// Two tabs of one file share the document: didOpen goes out for the first, didClose after the last.
    public func open(_ path: String, text: String, languageId: String) {
        let n = state.withLock { s in
            let n = s.opened[path, default: 0]
            s.opened[path] = n + 1
            if n == 0 { s.versions[path] = 1 }
            return n
        }
        guard n == 0 else { return }
        notify(
            "textDocument/didOpen",
            .obj([
                "textDocument": .obj([
                    "uri": Self.uri(path), "languageId": .string(languageId), "version": 1, "text": .string(text)
                ])
            ]))
    }
    public func change(_ path: String, text: String) {
        let v = state.withLock { s in
            let v = s.versions[path].map { $0 + 1 }
            if let v { s.versions[path] = v }
            return v
        }
        guard let v else { return }   // not open here (a server started after the tab)
        let params = JSONValue.obj([
            "textDocument": .obj(["uri": Self.uri(path), "version": .int(v)]),
            "contentChanges": .array([.obj(["text": .string(text)])])
        ])
        let write = state.withLock { s -> Int? in
            if let w = s.changes[path]?.write {
                s.changes[path] = (w, params)
                return nil
            }   // the queued write sends this, in its place
            s.nextWrite += 1
            s.changes[path] = (s.nextWrite, params)
            return s.nextWrite
        }
        guard let write else { return }
        let h = input.fileHandleForWriting
        writes.async { [weak self] in
            guard
                let p = self?.state.withLock({ s -> JSONValue? in
                    guard let c = s.changes[path], c.write == write else { return nil }
                    s.changes[path] = nil
                    return c.params
                }),
                let d = try? JSONEncoder().encode(
                    JSONValue.obj(["jsonrpc": "2.0", "method": "textDocument/didChange", "params": p]))
            else { return }
            try? h.write(contentsOf: LSPFramer.frame(d))
        }
    }
    public func close(_ path: String) {
        let (n, idle) = state.withLock { s in
            let n = s.opened[path] ?? 0
            s.opened[path] = n > 1 ? n - 1 : nil
            if n == 1 {
                s.versions[path] = nil
                s.changes[path] = nil
            }   // its queued write sends nothing now
            return (n, s.opened.isEmpty ? s.onIdle : nil)
        }
        guard n == 1 else { return }
        notify("textDocument/didClose", .obj(["textDocument": .obj(["uri": Self.uri(path)])]))
        idle?()
    }

    private func at(_ path: String, _ line: Int, _ col: Int) -> JSONValue {
        .obj(["textDocument": .obj(["uri": Self.uri(path)]), "position": Self.pos(line, col)])
    }

    public func definition(_ path: String, line: Int, column: Int) async throws -> CodeLocation? {
        let r = try await request("textDocument/definition", at(path, line, column))
        guard let l = r.array?.first ?? (r == .null ? nil : r) else { return nil }
        let uri = l["uri"]?.string ?? l["targetUri"]?.string
        let range = l["range"] ?? l["targetSelectionRange"]
        guard let uri, let p = URL(string: uri)?.path else { return nil }
        return CodeLocation(
            path: p, line: (range?["start"]?["line"]?.int ?? 0) + 1,
            column: (range?["start"]?["character"]?.int ?? 0) + 1)
    }

    public func completion(_ path: String, line: Int, column: Int) async throws -> [CodeCompletion] {
        Self.completions(try await request("textDocument/completion", at(path, line, column)))
    }

    private static let completionKinds = [
        2: "method", 3: "function", 4: "constructor", 5: "field", 6: "variable", 7: "class", 8: "interface",
        9: "module", 10: "property", 12: "value",
        13: "enum", 14: "keyword", 15: "snippet", 17: "file", 19: "folder", 20: "enum", 21: "constant", 22: "struct"
    ]

    static func completions(_ result: JSONValue) -> [CodeCompletion] {
        func edit(_ e: JSONValue, text: String? = nil) -> CodeEdit? {
            guard let r = e["range"] ?? e["replace"], let a = r["start"]?["line"]?.int,
                let b = r["start"]?["character"]?.int,
                let c = r["end"]?["line"]?.int, let d = r["end"]?["character"]?.int,
                let t = text ?? e["newText"]?.string
            else { return nil }
            return CodeEdit(line: a, column: b, endLine: c, endColumn: d, text: t)
        }
        let items = (result.array ?? result["items"]?.array ?? []).sorted {
            ($0["sortText"]?.string ?? "") < ($1["sortText"]?.string ?? "")
        }
        return items.prefix(200).map { i in
            let more = (i["additionalTextEdits"]?.array ?? []).compactMap { edit($0) }
            let doc = i["documentation"]
            return CodeCompletion(
                label: i["label"]?.string ?? "", detail: i["detail"]?.string,
                insert: i["textEdit"]?["newText"]?.string ?? i["insertText"]?.string ?? i["label"]?.string ?? "",
                kind: completionKinds[i["kind"]?.int ?? 0], documentation: doc?.string ?? doc?["value"]?.string,
                snippet: i["insertTextFormat"]?.int == 2 ? true : nil, edit: i["textEdit"].flatMap { edit($0) },
                more: more.isEmpty ? nil : more)
        }
    }

    /// The innermost function, method, class or module around a 1-based line (the test at the cursor).
    public func symbol(_ path: String, line: Int) async throws -> String? {
        Self.enclosingSymbol(
            try await request("textDocument/documentSymbol", .obj(["textDocument": .obj(["uri": Self.uri(path)])])),
            line: line)
    }

    /// From either shape of a documentSymbol result: nested `DocumentSymbol`s or flat `SymbolInformation`s. The smallest
    /// range wins; on a tie the later one (a child is visited after its parent).
    public func references(_ path: String, line: Int, column: Int) async throws -> [CodeLocation] {
        var params = at(path, line, column)
        if case .object(var o) = params {
            o["context"] = .obj(["includeDeclaration": true])
            params = .object(o)
        }
        return (try await request("textDocument/references", params).array ?? []).compactMap { l in
            guard let p = l["uri"]?.string.flatMap({ URL(string: $0)?.path }), let start = l["range"]?["start"] else {
                return nil
            }
            return CodeLocation(
                path: p, line: (start["line"]?.int ?? 0) + 1, column: (start["character"]?.int ?? 0) + 1)
        }
    }

    public func rename(_ path: String, line: Int, column: Int, to name: String) async throws -> [CodeFileEdit] {
        var params = at(path, line, column)
        if case .object(var o) = params {
            o["newName"] = .string(name)
            params = .object(o)
        }
        return Self.fileEdits(try await request("textDocument/rename", params))
    }

    /// The server's actions on a line, told the problems there: most quick fixes hang off them.
    public func actions(_ path: String, line: Int, column: Int) async throws -> [CodeAction] {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let all: [JSONValue] = state.withLock { $0.diagnostics[real] ?? $0.diagnostics[path] ?? [] }
        let here = all.filter { (d: JSONValue) -> Bool in
            guard let a = d["range"]?["start"]?["line"]?.int, let b = d["range"]?["end"]?["line"]?.int else {
                return false
            }
            return a <= line - 1 && line - 1 <= b
        }
        let point: JSONValue = .obj(["line": .int(line - 1), "character": .int(column - 1)])
        let found = try await request(
            "textDocument/codeAction",
            .obj([
                "textDocument": .obj(["uri": Self.uri(path)]), "range": .obj(["start": point, "end": point]),
                "context": .obj(["diagnostics": .array(here)])
            ]))
        return (found.array ?? []).compactMap { a in
            guard let title = a["title"]?.string, let edit = a["edit"] else { return nil }   // a command to run: the server's, no use here
            let files = Self.fileEdits(edit)
            return files.isEmpty ? nil : CodeAction(title: title, files: files)
        }
    }

    /// A WorkspaceEdit, in either of its shapes.
    static func fileEdits(_ edit: JSONValue) -> [CodeFileEdit] {
        func edits(_ list: JSONValue?) -> [CodeEdit] {
            (list?.array ?? []).compactMap { e in
                guard let a = e["range"]?["start"], let b = e["range"]?["end"], let l = a["line"]?.int,
                    let c = a["character"]?.int,
                    let el = b["line"]?.int, let ec = b["character"]?.int, let t = e["newText"]?.string
                else { return nil }
                return CodeEdit(line: l, column: c, endLine: el, endColumn: ec, text: t)
            }
        }
        var out: [CodeFileEdit] = []
        for d in edit["documentChanges"]?.array ?? [] {
            if let p = d["textDocument"]?["uri"]?.string.flatMap({ URL(string: $0)?.path }) {
                out.append(CodeFileEdit(path: p, edits: edits(d["edits"])))
            }
        }
        if case .object(let changes)? = edit["changes"] {
            for (uri, list) in changes.sorted(by: { $0.key < $1.key }) {
                if let p = URL(string: uri)?.path { out.append(CodeFileEdit(path: p, edits: edits(list))) }
            }
        }
        return out.filter { !$0.edits.isEmpty }
    }

    public func hover(_ path: String, line: Int, column: Int) async throws -> String? {
        Self.hoverText(try await request("textDocument/hover", at(path, line, column)))
    }

    public func signature(_ path: String, line: Int, column: Int) async throws -> CodeSignature? {
        Self.signature(try await request("textDocument/signatureHelp", at(path, line, column)))
    }

    /// `contents` comes in all three of the protocol's shapes: a MarkupContent, a MarkedString, a list of them.
    static func hoverText(_ result: JSONValue) -> String? {
        func text(_ c: JSONValue) -> String? {
            if let s = c.string { return s }
            guard let v = c["value"]?.string else { return nil }
            return c["language"]?.string.map { "```\($0)\n\(v)\n```" } ?? v
        }
        guard let c = result["contents"] else { return nil }
        let t = (c.array?.compactMap(text).joined(separator: "\n\n") ?? text(c))?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return t?.isEmpty == false ? t : nil
    }

    /// A parameter's label is its text, or its offsets in the signature's.
    static func signature(_ result: JSONValue) -> CodeSignature? {
        let all = result["signatures"]?.array ?? []
        guard !all.isEmpty else { return nil }
        let s = all[min(result["activeSignature"]?.int ?? 0, all.count - 1)]
        guard let label = s["label"]?.string else { return nil }
        let params = s["parameters"]?.array ?? [], n = s["activeParameter"]?.int ?? result["activeParameter"]?.int ?? 0
        guard params.indices.contains(n), let p = params[n]["label"] else { return CodeSignature(label: label) }
        if let name = p.string, let r = label.range(of: name) {
            let start = label.utf16.distance(from: label.startIndex, to: r.lowerBound)
            return CodeSignature(label: label, activeStart: start, activeEnd: start + name.utf16.count)
        }
        return CodeSignature(label: label, activeStart: p.array?.first?.int, activeEnd: p.array?.last?.int)
    }

    /// The file's symbols, nested ones in with the rest, top to bottom.
    public func symbols(_ path: String) async throws -> [CodeSymbol] {
        Self.symbols(
            try await request("textDocument/documentSymbol", .obj(["textDocument": .obj(["uri": Self.uri(path)])])))
    }

    private static let symbolKinds = [
        2: "module", 3: "namespace", 5: "class", 6: "method", 7: "property", 8: "field", 9: "initializer", 10: "enum",
        11: "interface", 12: "function", 13: "variable", 14: "constant", 22: "case", 23: "struct"
    ]

    /// The project's names matching `query`, as the server's index has them.
    public func workspaceSymbols(_ query: String) async throws -> [CodeSymbol] {
        Self.workspaceSymbols(try await request("workspace/symbol", .obj(["query": .string(query)])))
    }

    /// SymbolInformation or WorkspaceSymbol (which may leave the range out: the file's top).
    static func workspaceSymbols(_ result: JSONValue) -> [CodeSymbol] {
        (result.array ?? []).compactMap { s in
            let path = s["location"]?["uri"]?.string.flatMap { URL(string: $0)?.path }
            guard let name = s["name"]?.string, let path else { return nil }
            let line = (s["location"]?["range"]?["start"]?["line"]?.int ?? 0) + 1
            return CodeSymbol(name: name, kind: symbolKinds[s["kind"]?.int ?? 0] ?? "symbol", line: line, path: path)
        }
    }

    static func symbols(_ result: JSONValue) -> [CodeSymbol] {
        var out: [CodeSymbol] = []
        func visit(_ s: JSONValue) {
            let r = s["selectionRange"] ?? s["range"] ?? s["location"]?["range"]
            if let name = s["name"]?.string, let line = r?["start"]?["line"]?.int {
                out.append(CodeSymbol(name: name, kind: symbolKinds[s["kind"]?.int ?? 0] ?? "symbol", line: line + 1))
            }
            s["children"]?.array?.forEach(visit)
        }
        result.array?.forEach(visit)
        return out.sorted { $0.line < $1.line }
    }

    static func enclosingSymbol(_ result: JSONValue, line: Int) -> String? {
        var best: (name: String, span: Int)?
        func visit(_ s: JSONValue) {
            let r = s["range"] ?? s["location"]?["range"]
            if let name = s["name"]?.string, [2, 3, 5, 6, 12, 23].contains(s["kind"]?.int ?? 0),   // module, namespace, class, method, function, struct
                let a = r?["start"]?["line"]?.int, let b = r?["end"]?["line"]?.int, a < line, line - 1 <= b,
                b - a <= best?.span ?? .max
            {
                best = (name, b - a)
            }
            s["children"]?.array?.forEach(visit)
        }
        result.array?.forEach(visit)
        return best?.name
    }

    public func shutdown() {
        Task {
            _ = try? await request("shutdown", .null)
            notify("exit", .null)
        }
    }
}
