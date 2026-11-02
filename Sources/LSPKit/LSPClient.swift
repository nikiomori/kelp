import Foundation
import os
import Core

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
            guard let len = header.split(separator: "\r\n").compactMap({ l -> Int? in
                let p = l.split(separator: ":", maxSplits: 1)
                return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
            }).first, (0...Self.maxBody).contains(len) else { buf.removeSubrange(buf.startIndex..<r.upperBound); continue }
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
        proc.executableURL = URL(fileURLWithPath: exe); proc.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment; env["PATH"] = LoginPath.value; proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
        proc.standardInput = input; proc.standardOutput = output; proc.standardError = FileHandle.nullDevice
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
        state.withLock { $0.pending }.values.forEach { $0.resume(throwing: RPCError.internalError("language server stopped")) }
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
        let all = state.withLock { s in defer { s.pending = [:] }; s.exited = true; return s.pending }
        all.values.forEach { $0.resume(throwing: e) }
    }

    /// Decoded as plain JSON: ids may be numbers or strings.
    private func handle(_ body: Data) {
        guard let m = try? JSONDecoder().decode(JSONValue.self, from: body) else { return }
        let id = m["id"].flatMap { $0 == .null ? nil : $0 }
        if let method = m["method"]?.string {   // a request (workspace/configuration) gets null; of the notifications, only diagnostics count
            if let id { send(["jsonrpc": "2.0", "id": id, "result": .null]) }
            if method == "textDocument/publishDiagnostics", let p = m["params"], let (path, found) = Self.problems(p) { onProblems?(path, found) }
            return
        }
        guard let id = id?.int else { return }
        let c = state.withLock { s in s.timeouts = 0; return s.pending.removeValue(forKey: id) }
        if let e = m["error"], e != .null {
            c?.resume(throwing: RPCError(code: e["code"]?.int ?? -32603, message: e["message"]?.string ?? "language server error"))
        } else { c?.resume(returning: m["result"] ?? .null) }
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
                s.pending[s.nextID] = c; return s.nextID
            }
            guard let id else { c.resume(throwing: RPCError.internalError("language server exited")); return }
            send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let (c, hung) = state.withLock { s in
                    let c = s.pending.removeValue(forKey: id)
                    if c != nil { s.timeouts += 1 }
                    return (c, s.timeouts >= Self.timeoutsToGiveUp)
                }
                c?.resume(throwing: RPCError.internalError("no answer to \(method) from the language server in \(Int(timeout)) s"))
                if hung { fail(RPCError.internalError("the language server stopped answering")); terminate() }
            }
        }
    }
    public func notify(_ method: String, _ params: JSONValue) { send(["jsonrpc": "2.0", "method": .string(method), "params": params]) }

    public func initialize() async throws {
        let uri = URL(fileURLWithPath: root).absoluteString
        _ = try await request("initialize", .obj([
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)), "rootUri": .string(uri),
            "workspaceFolders": .array([.obj(["uri": .string(uri), "name": .string((root as NSString).lastPathComponent)])]),
            "capabilities": .obj(["textDocument": .obj(["definition": .obj([:]),
                                                   "completion": .obj(["completionItem": .obj(["snippetSupport": false])]),
                                                   "documentSymbol": .obj(["hierarchicalDocumentSymbolSupport": true])])])
        ]))
        notify("initialized", .obj([:]))
    }

    /// `publishDiagnostics`' params: errors and warnings, not the hints a server has for every other line.
    static func problems(_ params: JSONValue) -> (path: String, found: [CodeProblem])? {
        guard let uri = params["uri"]?.string, let path = URL(string: uri)?.path else { return nil }
        let found = (params["diagnostics"]?.array ?? []).compactMap { d -> CodeProblem? in
            guard let start = d["range"]?["start"], let end = d["range"]?["end"], let l = start["line"]?.int, let c = start["character"]?.int,
                  let el = end["line"]?.int, let ec = end["character"]?.int, let message = d["message"]?.string else { return nil }
            let severity = d["severity"]?.int ?? 1
            return severity <= 2 ? CodeProblem(line: l, column: c, endLine: el, endColumn: ec, isError: severity == 1, message: message) : nil
        }
        return (path, found)
    }

    static func uri(_ path: String) -> JSONValue { .string(URL(fileURLWithPath: path).absoluteString) }
    static func pos(_ line: Int, _ col: Int) -> JSONValue { .obj(["line": .int(line - 1), "character": .int(col - 1)]) }

    /// One server can serve several languages (typescript, javascriptreact…), so each file says which it is.
    /// Two tabs of one file share the document: didOpen goes out for the first, didClose after the last.
    public func open(_ path: String, text: String, languageId: String) {
        let n = state.withLock { s in let n = s.opened[path, default: 0]; s.opened[path] = n + 1; if n == 0 { s.versions[path] = 1 }; return n }
        guard n == 0 else { return }
        notify("textDocument/didOpen",
               .obj(["textDocument": .obj(["uri": Self.uri(path), "languageId": .string(languageId), "version": 1, "text": .string(text)])]))
    }
    public func change(_ path: String, text: String) {
        let v = state.withLock { s in let v = s.versions[path].map { $0 + 1 }; if let v { s.versions[path] = v }; return v }
        guard let v else { return }   // not open here (a server started after the tab)
        let params = JSONValue.obj(["textDocument": .obj(["uri": Self.uri(path), "version": .int(v)]),
                                    "contentChanges": .array([.obj(["text": .string(text)])])])
        let write = state.withLock { s -> Int? in
            if let w = s.changes[path]?.write { s.changes[path] = (w, params); return nil }   // the queued write sends this, in its place
            s.nextWrite += 1; s.changes[path] = (s.nextWrite, params); return s.nextWrite
        }
        guard let write else { return }
        let h = input.fileHandleForWriting
        writes.async { [weak self] in
            guard let p = self?.state.withLock({ s -> JSONValue? in
                      guard let c = s.changes[path], c.write == write else { return nil }
                      s.changes[path] = nil; return c.params
                  }),
                  let d = try? JSONEncoder().encode(JSONValue.obj(["jsonrpc": "2.0", "method": "textDocument/didChange", "params": p])) else { return }
            try? h.write(contentsOf: LSPFramer.frame(d))
        }
    }
    public func close(_ path: String) {
        let (n, idle) = state.withLock { s in
            let n = s.opened[path] ?? 0; s.opened[path] = n > 1 ? n - 1 : nil
            if n == 1 { s.versions[path] = nil; s.changes[path] = nil }   // its queued write sends nothing now
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
        return CodeLocation(path: p, line: (range?["start"]?["line"]?.int ?? 0) + 1, column: (range?["start"]?["character"]?.int ?? 0) + 1)
    }

    public func completion(_ path: String, line: Int, column: Int) async throws -> [CodeCompletion] {
        let r = try await request("textDocument/completion", at(path, line, column))
        let items = r.array ?? r["items"]?.array ?? []
        return items.prefix(200).map {
            CodeCompletion(label: $0["label"]?.string ?? "", detail: $0["detail"]?.string,
                           insert: $0["insertText"]?.string ?? $0["textEdit"]?["newText"]?.string ?? $0["label"]?.string ?? "")
        }
    }

    /// The innermost function, method, class or module around a 1-based line (the test at the cursor).
    public func symbol(_ path: String, line: Int) async throws -> String? {
        Self.enclosingSymbol(try await request("textDocument/documentSymbol", .obj(["textDocument": .obj(["uri": Self.uri(path)])])), line: line)
    }

    /// From either shape of a documentSymbol result: nested `DocumentSymbol`s or flat `SymbolInformation`s. The smallest
    /// range wins; on a tie the later one (a child is visited after its parent).
    static func enclosingSymbol(_ result: JSONValue, line: Int) -> String? {
        var best: (name: String, span: Int)?
        func visit(_ s: JSONValue) {
            let r = s["range"] ?? s["location"]?["range"]
            if let name = s["name"]?.string, [2, 3, 5, 6, 12, 23].contains(s["kind"]?.int ?? 0),   // module, namespace, class, method, function, struct
               let a = r?["start"]?["line"]?.int, let b = r?["end"]?["line"]?.int, a < line, line - 1 <= b, b - a <= best?.span ?? .max {
                best = (name, b - a)
            }
            s["children"]?.array?.forEach(visit)
        }
        result.array?.forEach(visit)
        return best?.name
    }

    public func shutdown() { Task { _ = try? await request("shutdown", .null); notify("exit", .null) } }
}
