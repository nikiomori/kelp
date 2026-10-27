import Foundation
import os
import Core
import LSPKit

/// Language servers, one per (project, server command), shared by every client: started for the first file a trusted
/// project opens; one that died starts again on the next open (its open files with it), at most once per `retryDelay`;
/// one with no file open for `idleDelay` stops. Opens, changes and closes come in order from a connection's reader thread
/// and stay quick: while a server starts they're queued, and given to it once it's up. A restarted server gets each open
/// file's text as last sent (unsaved edits included), not what's on disk.
final class LSPHost: Sendable {
    struct Key: Hashable, Sendable { let root: String, argv: [String] }
    private enum DocOp: Sendable { case open(path: String, text: String, languageId: String), change(path: String, text: String), close(path: String) }
    private enum Server: Sendable {
        case starting(pending: [DocOp], ready: Task<LSPClient?, Never>?)
        case running(LSPClient)
        case failed
    }
    /// A file open in some tab: its server, its language, how many opens it has and its text as last sent.
    private struct Doc: Sendable { let key: Key, path: String, languageId: String; var count: Int, text: String }
    private struct State {
        var servers: [Key: Server] = [:]
        var docs: [String: Doc] = [:]           // "root|path"
        var owners: [Int: [String: Int]] = [:]  // connection → the docs it opened, and how many times
        var started: [Key: Date] = [:]          // a broken server isn't started again on every open
        var closed = false                      // the daemon stopped them all: an open arriving after starts none
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A broken server isn't started again on every open.
    let retryDelay: TimeInterval
    /// How long a server with no open file keeps running (a tab closed and opened again doesn't restart it).
    let idleDelay: TimeInterval

    let store: Store   // who trusted which project (`lsp.trusted`, written by Kelp's window)
    let remotes: Remotes

    /// Tests shorten the delays.
    init(store: Store, remotes: Remotes, retryDelay: TimeInterval, idleDelay: TimeInterval) {
        self.store = store
        self.remotes = remotes
        self.retryDelay = retryDelay
        self.idleDelay = idleDelay
    }

    func open(conn: Int, _ o: LSPOpen) {
        let key = Key(root: o.root, argv: [o.command] + (o.args ?? [])), id = o.root + "|" + o.path
        let launch = state.withLock { s -> Bool in
            guard !s.closed else { return false }
            s.docs[id, default: Doc(key: key, path: o.path, languageId: o.languageId, count: 0, text: o.text)].count += 1
            s.docs[id]?.text = o.text
            s.owners[conn, default: [:]][id, default: 0] += 1
            let op = DocOp.open(path: o.path, text: o.text, languageId: o.languageId)
            switch s.servers[key] {
            case .running(let c)? where c.isRunning: Self.apply(op, to: c); return false
            case .starting(let pending, let ready)?: s.servers[key] = .starting(pending: pending + [op], ready: ready); return false
            default:   // none yet, or it died: a new one gets every file open for it, as last sent
                if let at = s.started[key], Date().timeIntervalSince(at) < retryDelay { return false }
                s.started[key] = Date()
                let others = s.docs.filter { $0.key != id && $0.value.key == key }.values.flatMap { d in
                    Array(repeating: DocOp.open(path: d.path, text: d.text, languageId: d.languageId), count: d.count)
                }
                s.servers[key] = .starting(pending: others + Array(repeating: op, count: s.docs[id]?.count ?? 1), ready: nil)
                return true
            }
        }
        if launch { start(key) }
    }

    func change(_ root: String, _ path: String, text: String) {
        let id = root + "|" + path
        state.withLock { s in
            guard let d = s.docs[id] else { return }
            s.docs[id]?.text = text
            Self.send(.change(path: path, text: text), to: d.key, in: &s)
        }
    }

    func close(conn: Int, _ root: String, _ path: String) {
        let id = root + "|" + path
        let idle = state.withLock { s -> Key? in
            guard let n = s.owners[conn]?[id], n > 0, var d = s.docs[id] else { return nil }   // not opened by this connection
            s.owners[conn]?[id] = n > 1 ? n - 1 : nil
            if s.owners[conn]?.isEmpty == true { s.owners[conn] = nil }
            d.count -= 1; s.docs[id] = d.count > 0 ? d : nil
            Self.send(.close(path: path), to: d.key, in: &s)
            return s.docs.values.contains { $0.key == d.key } ? nil : d.key
        }
        if let idle { stopLater(idle) }
    }

    /// A connection that went: what it opened is closed.
    func closeAll(conn: Int) {
        let opened = state.withLock { s in (s.owners[conn] ?? [:]).compactMap { id, n in s.docs[id].map { ($0.key.root, $0.path, n) } } }
        for (root, path, n) in opened { for _ in 0..<n { close(conn: conn, root, path) } }
    }

    /// The running server of an open file, waiting for one that's starting; nil when there's none.
    func client(_ root: String, _ path: String) async -> LSPClient? {
        let (c, ready) = state.withLock { s -> (LSPClient?, Task<LSPClient?, Never>?) in
            guard let d = s.docs[root + "|" + path] else { return (nil, nil) }
            switch s.servers[d.key] {
            case .running(let c)?: return (c.isRunning ? c : nil, nil)
            case .starting(_, let ready)?: return (nil, ready)
            default: return (nil, nil)
            }
        }
        if let c { return c }
        return await ready?.value
    }

    /// The daemon is stopping: so do its servers.
    func stopAll() {
        let all = state.withLock { s in
            s.closed = true
            defer { s.servers = [:] }
            return s.servers.values.compactMap { if case .running(let c) = $0 { c } else { nil } }
        }
        // Gone before this returns: the daemon stops or execs next, and a SIGKILL left for later would never come.
        DispatchQueue.concurrentPerform(iterations: all.count) { all[$0].terminateNow() }
    }

    private func start(_ key: Key) {
        let ready = Task.detached { [self] () -> LSPClient? in
            // On a thread of its own: a cold login-shell PATH (LoginPath) takes up to 8 s, too long to hold a pool thread.
            // Handed over under a lock: the Thread Sanitizer doesn't see a continuation resumed from that thread order
            // the client's init before its use here, and reported its fields as raced.
            let made = OSAllocatedUnfairLock<LSPClient?>(initialState: nil)
            await withCheckedContinuation { c in
                Thread.detachNewThread {
                    let client = LSPClient(argv: key.argv, root: key.root)
                    made.withLock { $0 = client }
                    c.resume()
                }
            }
            var up = made.withLock { $0 }
            if let started = up {
                do { try await started.initialize() } catch {
                    Log.session.error("language server \(key.argv.joined(separator: " "), privacy: .public) didn't start: \(error)")
                    started.terminate(); up = nil
                }
            }
            let c = up
            let live = state.withLock { s -> LSPClient? in
                guard case .starting(let pending, _)? = s.servers[key] else { return nil }   // stopped meanwhile
                guard let c else { s.servers[key] = .failed; return nil }
                pending.forEach { Self.apply($0, to: c) }
                s.servers[key] = .running(c)
                return c
            }
            if live == nil { c?.terminate() }
            stopLater(key)   // started only to close a file, say
            return live
        }
        state.withLock { s in if case .starting(let pending, nil)? = s.servers[key] { s.servers[key] = .starting(pending: pending, ready: ready) } }
    }

    private static func send(_ op: DocOp, to key: Key, in s: inout State) {
        switch s.servers[key] {
        case .running(let c)?: apply(op, to: c)
        case .starting(let pending, let ready)?: s.servers[key] = .starting(pending: pending + [op], ready: ready)
        default: break
        }
    }

    /// Under the host's lock: the client's own lock is taken inside it, never the other way round.
    private static func apply(_ op: DocOp, to c: LSPClient) {
        switch op {
        case .open(let p, let text, let lang): c.open(p, text: text, languageId: lang)
        case .change(let p, let text): c.change(p, text: text)
        case .close(let p): c.close(p)
        }
    }

    /// Stops `key`'s server `idleDelay` from now if no file is open for it then.
    private func stopLater(_ key: Key) {
        DispatchQueue.global().asyncAfter(deadline: .now() + idleDelay) { [self] in
            let idle = state.withLock { s -> LSPClient? in
                guard !s.docs.values.contains(where: { $0.key == key }), case .running(let c)? = s.servers[key] else { return nil }
                s.servers[key] = nil; s.started[key] = nil
                return c
            }
            idle?.shutdown()
        }
    }
}

// MARK: methods

extension LSPHost {
    /// The user trusted `root` for language servers and formatters in Kelp's window (`state.set` of `lsp.trusted`, which
    /// only the window may write).
    func trusted(_ root: String) -> Bool {
        ((try? store.uiState(prefix: LSPOpen.trustKey))?[LSPOpen.trustKey]?.array ?? []).contains(.string(root))
    }
}

extension Methods {
    static let lspMethods: [any Handled.Type] = [LSPOpen.self, LSPChange.self, LSPClose.self]
    static let lspAsyncMethods: [any AsyncHandled.Type] = [LSPDefinition.self, LSPCompletion.self, LSPSymbol.self]
}

extension LSPOpen: Handled {
    /// Before the changes typed after it. Quick: a server starts on a task of its own.
    static var inOrder: Bool { true }
    func handle(_ lsp: LSPHost) throws -> Done { try handle(lsp, conn: -1) }
    func handle(_ lsp: LSPHost, conn: Int) throws -> Done {
        guard lsp.remotes.of(root) == nil else { throw RPCError.invalidParams("No language servers for a project on another machine.") }
        // A project's language servers run its own code: the daemon checks, whoever asks.
        guard lsp.trusted(root) else { throw LSPRefusal.untrusted.error }
        // Not waiting for the login shell's PATH on this thread (seconds, right after the daemon starts): until it's read,
        // a server that isn't installed fails when it starts, off this thread, and the tab just gets no server.
        do { _ = try LoginPath.resolveNow(command) } catch { throw LSPRefusal.notInstalled(command).error }
        lsp.open(conn: conn, self)
        return Done()
    }
}

extension LSPChange: Handled {
    static var inOrder: Bool { true }   // keystrokes' text, in the order typed
    func handle(_ lsp: LSPHost) throws -> Done { lsp.change(root, path, text: text); return Done() }
}

extension LSPClose: Handled {
    static var inOrder: Bool { true }
    func handle(_ lsp: LSPHost) throws -> Done { try handle(lsp, conn: -1) }
    func handle(_ lsp: LSPHost, conn: Int) throws -> Done { lsp.close(conn: conn, root, path); return Done() }
}

extension LSPDefinition: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> CodeLocation? {
        guard let c = await lsp.client(root, path) else { return nil }
        return try await c.definition(path, line: line, column: column)
    }
}

extension LSPCompletion: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> [CodeCompletion] {
        guard let c = await lsp.client(root, path) else { return [] }
        return try await c.completion(path, line: line, column: column)
    }
}

extension LSPSymbol: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> String? {
        guard let c = await lsp.client(root, path) else { return nil }
        return try await c.symbol(path, line: line)
    }
}
