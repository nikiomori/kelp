import Core
import Foundation
import LSPKit
import os

/// Language servers, one per (project, server command), shared by every client: started for the first file a trusted
/// project opens; one that died starts again on the next open (its open files with it), at most once per `retryDelay`;
/// one with no file open for `idleDelay` stops. Opens, changes and closes come in order from a connection's reader thread
/// and stay quick: while a server starts they're queued, and given to it once it's up. A restarted server gets each open
/// file's text as last sent (unsaved edits included), not what's on disk.
final class LSPHost: Sendable {
    struct Key: Hashable, Sendable { let root: String, argv: [String] }
    private enum DocOp: Sendable {
        case open(path: String, text: String, languageId: String), change(path: String, text: String), close(
            path: String)
    }
    private enum Server: Sendable {
        case starting(pending: [DocOp], ready: Task<LSPClient?, Never>?)
        case running(LSPClient)
        case failed
    }
    /// A file open in some tab: its server, its language, how many opens it has and its text as last sent.
    private struct Doc: Sendable {
        let key: Key, path: String, languageId: String
        var count: Int, text: String
    }
    private struct State {
        var servers: [Key: Server] = [:]
        var docs: [String: Doc] = [:]   // "root|path"
        var owners: [Int: [String: Int]] = [:]   // connection → the docs it opened, and how many times
        var started: [Key: Date] = [:]   // a broken server isn't started again on every open
        var closed = false   // the daemon stopped them all: an open arriving after starts none
        var problems: [String: [CodeProblem]] = [:]   // by the path a tab has it open under
        var problemsChanged: (@Sendable (String) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A broken server isn't started again on every open.
    let retryDelay: TimeInterval
    /// How long a server with no open file keeps running (a tab closed and opened again doesn't restart it).
    let idleDelay: TimeInterval

    let store: Store   // who trusted which project (`lsp.trusted`, written by Kelp's window)
    let remotes: Remotes
    /// Where files are read for an answer (references' lines): never the cooperative pool.
    let offloads: Slots

    /// Tests shorten the delays.
    init(store: Store, remotes: Remotes, offloads: Slots, retryDelay: TimeInterval, idleDelay: TimeInterval) {
        self.store = store
        self.remotes = remotes
        self.offloads = offloads
        self.retryDelay = retryDelay
        self.idleDelay = idleDelay
    }

    func open(conn: Int, _ request: LSPOpen) {
        let key = Key(root: request.root, argv: [request.command] + (request.args ?? [])),
            id = request.root + "|" + request.path
        let launch = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.docs[
                id,
                default: Doc(key: key, path: request.path, languageId: request.languageId, count: 0, text: request.text)
            ].count +=
                1
            state.docs[id]?.text = request.text
            state.owners[conn, default: [:]][id, default: 0] += 1
            let op = DocOp.open(path: request.path, text: request.text, languageId: request.languageId)
            switch state.servers[key] {
            case .running(let client)? where client.isRunning:
                Self.apply(op, to: client)
                return false
            case .starting(let pending, let ready)?:
                state.servers[key] = .starting(pending: pending + [op], ready: ready)
                return false
            default:   // none yet, or it died: a new one gets every file open for it, as last sent
                if let at = state.started[key], Date().timeIntervalSince(at) < retryDelay { return false }
                state.started[key] = Date()
                let others = state.docs.filter { $0.key != id && $0.value.key == key }.values.flatMap { doc in
                    Array(
                        repeating: DocOp.open(path: doc.path, text: doc.text, languageId: doc.languageId),
                        count: doc.count)
                }
                state.servers[key] = .starting(
                    pending: others + Array(repeating: op, count: state.docs[id]?.count ?? 1), ready: nil)
                return true
            }
        }
        if launch { start(key) }
    }

    func change(_ root: String, _ path: String, text: String) {
        let id = root + "|" + path
        state.withLock { state in
            guard let doc = state.docs[id] else { return }
            state.docs[id]?.text = text
            Self.send(.change(path: path, text: text), to: doc.key, in: &state)
        }
    }

    /// `changed`: a file's problems are new. Set once.
    func whenProblemsChange(_ changed: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.problemsChanged = changed }
    }

    func problems(_ path: String) -> [CodeProblem] { state.withLock { $0.problems[path] ?? [] } }

    /// A server may name a file by its real path (/private/tmp), a tab by the one it was given. Kept only for a file open in
    /// a tab (a server may report on the whole project, and the next open is told again); the paths are resolved outside
    /// the lock, which opens and changes take on a connection's reader thread.
    private func heard(_ reported: String, _ found: [CodeProblem]) {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let open = state.withLock { s in Set(s.docs.values.map(\.path)) }
        let target = real(reported)
        guard let path = open.contains(reported) ? reported : open.first(where: { real($0) == target }) else { return }
        let changed = state.withLock { state -> (@Sendable (String) -> Void)? in
            guard state.docs.values.contains(where: { $0.path == path }) else { return nil }   // closed meanwhile
            state.problems[path] = found.isEmpty ? nil : found
            return state.problemsChanged
        }
        changed?(path)
    }

    func close(conn: Int, _ root: String, _ path: String) {
        let id = root + "|" + path
        let idle = state.withLock { state -> Key? in
            // not opened by this connection
            guard let opens = state.owners[conn]?[id], opens > 0, var doc = state.docs[id] else { return nil }
            state.owners[conn]?[id] = opens > 1 ? opens - 1 : nil
            if state.owners[conn]?.isEmpty == true { state.owners[conn] = nil }
            doc.count -= 1
            state.docs[id] = doc.count > 0 ? doc : nil
            if doc.count == 0 { state.problems[path] = nil }   // the last tab on it, of any connection
            Self.send(.close(path: path), to: doc.key, in: &state)
            return state.docs.values.contains { $0.key == doc.key } ? nil : doc.key
        }
        if let idle { stopLater(idle) }
    }

    /// A connection that went: what it opened is closed.
    func closeAll(conn: Int) {
        let opened = state.withLock { state in
            (state.owners[conn] ?? [:]).compactMap { id, opens in state.docs[id].map { ($0.key.root, $0.path, opens) } }
        }
        for (root, path, opens) in opened { for _ in 0..<opens { close(conn: conn, root, path) } }
    }

    /// The running server of an open file, waiting for one that's starting; nil when there's none.
    func client(_ root: String, _ path: String) async -> LSPClient? {
        let (running, ready) = state.withLock { state -> (LSPClient?, Task<LSPClient?, Never>?) in
            guard let doc = state.docs[root + "|" + path] else { return (nil, nil) }
            switch state.servers[doc.key] {
            case .running(let client)?: return (client.isRunning ? client : nil, nil)
            case .starting(_, let ready)?: return (nil, ready)
            default: return (nil, nil)
            }
        }
        if let running { return running }
        return await ready?.value
    }

    /// The daemon is stopping: so do its servers.
    func stopAll() {
        let all = state.withLock { state in
            state.closed = true
            defer { state.servers = [:] }
            return state.servers.values.compactMap { if case .running(let client) = $0 { client } else { nil } }
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
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    let client = LSPClient(argv: key.argv, root: key.root) { [weak self] path, found in
                        self?.heard(path, found)
                    }
                    made.withLock { $0 = client }
                    continuation.resume()
                }
            }
            var up = made.withLock { $0 }
            if let started = up {
                do { try await started.initialize() } catch {
                    Log.session.error(
                        "language server \(key.argv.joined(separator: " "), privacy: .public) didn't start: \(error)")
                    started.terminate()
                    up = nil
                }
            }
            let client = up
            let live = state.withLock { state -> LSPClient? in
                guard case .starting(let pending, _)? = state.servers[key] else { return nil }   // stopped meanwhile
                guard let client else {
                    state.servers[key] = .failed
                    return nil
                }
                pending.forEach { Self.apply($0, to: client) }
                state.servers[key] = .running(client)
                return client
            }
            if live == nil { client?.terminate() }
            stopLater(key)   // started only to close a file, say
            return live
        }
        state.withLock { state in
            if case .starting(let pending, nil)? = state.servers[key] {
                state.servers[key] = .starting(pending: pending, ready: ready)
            }
        }
    }

    private static func send(_ op: DocOp, to key: Key, in state: inout State) {
        switch state.servers[key] {
        case .running(let client)?: apply(op, to: client)
        case .starting(let pending, let ready)?: state.servers[key] = .starting(pending: pending + [op], ready: ready)
        default: break
        }
    }

    /// Under the host's lock: the client's own lock is taken inside it, never the other way round.
    private static func apply(_ op: DocOp, to client: LSPClient) {
        switch op {
        case .open(let path, let text, let lang): client.open(path, text: text, languageId: lang)
        case .change(let path, let text): client.change(path, text: text)
        case .close(let path): client.close(path)
        }
    }

    /// Stops `key`'s server `idleDelay` from now if no file is open for it then.
    private func stopLater(_ key: Key) {
        DispatchQueue.global().asyncAfter(deadline: .now() + idleDelay) { [self] in
            let idle = state.withLock { state -> LSPClient? in
                guard !state.docs.values.contains(where: { $0.key == key }),
                    case .running(let client)? = state.servers[key]
                else {
                    return nil
                }
                state.servers[key] = nil
                state.started[key] = nil
                return client
            }
            idle?.shutdown()
        }
    }
}
