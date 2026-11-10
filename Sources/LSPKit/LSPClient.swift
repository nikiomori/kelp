import Core
import Foundation
import os

private let lspLog = Logger.kelp("lsp")

/// `Content-Length` framed JSON-RPC, as LSP speaks over stdio.
public struct LSPFramer: Sendable {
    private var buf = Data()
    static let maxBody = 256 << 20
    public init() {}
    public static func frame(_ body: Data) -> Data { Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body }
    public mutating func append(_ chunk: Data) -> [Data] {
        buf.append(chunk)
        var out: [Data] = []
        let sep = Data("\r\n\r\n".utf8)
        while let headerEnd = buf.range(of: sep) {
            let header = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            // A missing, negative or absurd length is a broken header: skip it rather than trap or wait forever.
            guard
                let len = header.split(separator: "\r\n").compactMap({ line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    return parts.count == 2 && parts[0].lowercased() == "content-length"
                        ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                }).first, (0...Self.maxBody).contains(len)
            else {
                buf.removeSubrange(buf.startIndex..<headerEnd.upperBound)
                continue
            }
            guard buf.distance(from: headerEnd.upperBound, to: buf.endIndex) >= len else { break }
            let end = buf.index(headerEnd.upperBound, offsetBy: len)
            out.append(Data(buf[headerEnd.upperBound..<end]))
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
        guard let cmd = argv.first, let exe = LoginPath.find(cmd) else { return nil }
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
                while case let count = read(reading.fileDescriptor, &buf, buf.count),
                    count > 0 || (count < 0 && errno == EINTR)
                {
                    guard count > 0 else { continue }
                    for body in framer.append(Data(buf[0..<count])) { self?.handle(body) }
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

    private func fail(_ error: RPCError) {
        let all = state.withLock { locked in
            defer { locked.pending = [:] }
            locked.exited = true
            return locked.pending
        }
        all.values.forEach { $0.resume(throwing: error) }
    }

    /// Decoded as plain JSON: ids may be numbers or strings.
    private func handle(_ body: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else { return }
        let id = message["id"].flatMap { $0 == .null ? nil : $0 }
        if let method = message["method"]?.string {   // a request (workspace/configuration) gets null; of the notifications, only diagnostics count
            if let id { send(["jsonrpc": "2.0", "id": id, "result": .null]) }
            if method == "textDocument/publishDiagnostics", let params = message["params"],
                let (path, found) = Self.problems(params)
            {
                state.withLock { $0.diagnostics[path] = params["diagnostics"]?.array }
                onProblems?(path, found)
            }
            return
        }
        guard let id = id?.int else { return }
        let waiting = state.withLock { locked in
            locked.timeouts = 0
            return locked.pending.removeValue(forKey: id)
        }
        if let error = message["error"], error != .null {
            // The server's own code means nothing to Kelp's clients, who'd read it as one of Kelp's (-32602 bad params…).
            waiting?.resume(
                throwing: RPCError.internalError(
                    "language server: \(error["message"]?.string ?? "error \(error["code"]?.int ?? 0)")"))
        } else {
            waiting?.resume(returning: message["result"] ?? .null)
        }
    }

    /// Encoded on the write queue too: didChange sends the whole document, and the caller is usually the main thread.
    private func send(_ message: [String: JSONValue]) {
        let handle = input.fileHandleForWriting   // not self: a blocked write must not keep the client alive
        writes.async {
            lspLog.attempt("writing to a language server") {
                try handle.write(contentsOf: LSPFramer.frame(JSONEncoder().encode(JSONValue.object(message))))
            }
        }
    }

    func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let id = state.withLock { locked -> Int? in
                guard !locked.exited else { return nil }
                defer { locked.nextID += 1 }
                locked.pending[locked.nextID] = continuation
                return locked.nextID
            }
            guard let id else {
                continuation.resume(throwing: RPCError.internalError("language server exited"))
                return
            }
            send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let (waiting, hung) = state.withLock { locked in
                    let waiting = locked.pending.removeValue(forKey: id)
                    if waiting != nil { locked.timeouts += 1 }
                    return (waiting, locked.timeouts >= Self.timeoutsToGiveUp)
                }
                waiting?.resume(
                    throwing: RPCError.internalError(
                        "no answer to \(method) from the language server in \(Int(timeout)) s"))
                if hung {
                    fail(RPCError.internalError("the language server stopped answering"))
                    terminate()
                }
            }
        }
    }
    func notify(_ method: String, _ params: JSONValue) {
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
        let found = (params["diagnostics"]?.array ?? []).compactMap { diagnostic -> CodeProblem? in
            guard let span = span(diagnostic["range"]), let message = diagnostic["message"]?.string else { return nil }
            let severity = diagnostic["severity"]?.int ?? 1
            return severity <= 2
                ? CodeProblem(
                    line: span.line, column: span.column, endLine: span.endLine, endColumn: span.endColumn,
                    isError: severity == 1, message: message)
                : nil
        }
        return (path, found)
    }

    /// An LSP range's start and end, nil when any of the four is missing.
    static func span(_ range: JSONValue?) -> (line: Int, column: Int, endLine: Int, endColumn: Int)? {
        guard let start = range?["start"], let end = range?["end"], let line = start["line"]?.int,
            let column = start["character"]?.int, let endLine = end["line"]?.int, let endColumn = end["character"]?.int
        else { return nil }
        return (line, column, endLine, endColumn)
    }

    static func uri(_ path: String) -> JSONValue { .string(URL(fileURLWithPath: path).absoluteString) }
    static func pos(_ line: Int, _ col: Int) -> JSONValue {
        .obj(["line": .int(line - 1), "character": .int(col - 1)])
    }

    /// One server can serve several languages (typescript, javascriptreact…), so each file says which it is.
    /// Two tabs of one file share the document: didOpen goes out for the first, didClose after the last.
    public func open(_ path: String, text: String, languageId: String) {
        let tabs = state.withLock { locked in
            let tabs = locked.opened[path, default: 0]
            locked.opened[path] = tabs + 1
            if tabs == 0 { locked.versions[path] = 1 }
            return tabs
        }
        guard tabs == 0 else { return }
        notify(
            "textDocument/didOpen",
            .obj([
                "textDocument": .obj([
                    "uri": Self.uri(path), "languageId": .string(languageId), "version": 1, "text": .string(text)
                ])
            ]))
    }
    public func change(_ path: String, text: String) {
        let version = state.withLock { locked in
            let version = locked.versions[path].map { $0 + 1 }
            if let version { locked.versions[path] = version }
            return version
        }
        guard let version else { return }   // not open here (a server started after the tab)
        let params = JSONValue.obj([
            "textDocument": .obj(["uri": Self.uri(path), "version": .int(version)]),
            "contentChanges": .array([.obj(["text": .string(text)])])
        ])
        let write = state.withLock { locked -> Int? in
            if let queued = locked.changes[path]?.write {
                locked.changes[path] = (queued, params)
                return nil
            }   // the queued write sends this, in its place
            locked.nextWrite += 1
            locked.changes[path] = (locked.nextWrite, params)
            return locked.nextWrite
        }
        guard let write else { return }
        let handle = input.fileHandleForWriting
        writes.async { [weak self] in
            guard
                let latest = self?.state.withLock({ locked -> JSONValue? in
                    guard let change = locked.changes[path], change.write == write else { return nil }
                    locked.changes[path] = nil
                    return change.params
                })
            else { return }
            lspLog.attempt("writing a change to a language server") {
                let message = JSONValue.obj(["jsonrpc": "2.0", "method": "textDocument/didChange", "params": latest])
                try handle.write(contentsOf: LSPFramer.frame(JSONEncoder().encode(message)))
            }
        }
    }
    public func close(_ path: String) {
        let (tabs, idle) = state.withLock { locked in
            let tabs = locked.opened[path] ?? 0
            locked.opened[path] = tabs > 1 ? tabs - 1 : nil
            if tabs == 1 {
                locked.versions[path] = nil
                locked.changes[path] = nil
            }   // its queued write sends nothing now
            return (tabs, locked.opened.isEmpty ? locked.onIdle : nil)
        }
        guard tabs == 1 else { return }
        notify("textDocument/didClose", .obj(["textDocument": .obj(["uri": Self.uri(path)])]))
        idle?()
    }

    func at(_ path: String, _ line: Int, _ col: Int) -> JSONValue {
        .obj(["textDocument": .obj(["uri": Self.uri(path)]), "position": Self.pos(line, col)])
    }

    /// The server's actions on a line, told the problems there: most quick fixes hang off them.
    public func actions(_ path: String, line: Int, column: Int) async throws -> [CodeAction] {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let all: [JSONValue] = state.withLock { $0.diagnostics[real] ?? $0.diagnostics[path] ?? [] }
        let here = all.filter { (diagnostic: JSONValue) -> Bool in
            guard let start = diagnostic["range"]?["start"]?["line"]?.int,
                let end = diagnostic["range"]?["end"]?["line"]?.int
            else {
                return false
            }
            return start <= line - 1 && line - 1 <= end
        }
        let point: JSONValue = .obj(["line": .int(line - 1), "character": .int(column - 1)])
        let found = try await request(
            "textDocument/codeAction",
            .obj([
                "textDocument": .obj(["uri": Self.uri(path)]), "range": .obj(["start": point, "end": point]),
                "context": .obj(["diagnostics": .array(here)])
            ]))
        return (found.array ?? []).compactMap { action in
            guard let title = action["title"]?.string, let edit = action["edit"] else { return nil }   // a command to run: the server's, no use here
            let files = Self.fileEdits(edit)
            return files.isEmpty ? nil : CodeAction(title: title, files: files)
        }
    }

    public func shutdown() {
        Task {
            _ = try? await request("shutdown", .null)
            notify("exit", .null)
        }
    }
}
