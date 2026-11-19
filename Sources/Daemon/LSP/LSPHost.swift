import Core
import Foundation
import LSPKit
import os

/// Runs the language servers, one per (project, server command), shared by every client. A server starts for the first
/// file a trusted project opens. A file may be open in several servers (its language's own and a linter), each
/// independently. A server that died starts again on the next open (with its open files), at most once per
/// `retryDelay`. A server with no file open for `idleDelay` stops.
/// Opens, changes and closes come in order from a connection's reader thread and must stay quick, so while a server
/// starts they are queued and handed to it once it is up. A restarted server gets each open file's text as last sent
/// (unsaved edits included), not what is on disk.
final class LSPHost: Sendable {
    struct Key: Hashable, Sendable {
        let root: String, argv: [String]
        var options: JSONValue?, settings: JSONValue?
    }
    /// Names one file as opened at one of the file's servers.
    private struct DocID: Hashable, Sendable { let key: Key, path: String }
    private enum DocOp: Sendable {
        case open(path: String, text: String, languageId: String), change(path: String, text: String), close(
            path: String)
    }
    private enum Server: Sendable {
        case starting(pending: [DocOp], ready: Task<LSPClient?, Never>?)
        case running(LSPClient)
        case failed
    }
    /// A file that is open in some tab, at one server. It holds the file's language, this server's place among the
    /// file's servers, how many times the file is open, and its text as last sent.
    private struct Doc: Sendable {
        let languageId: String, order: Int
        var count: Int, text: String
    }
    private struct State {
        var servers: [Key: Server] = [:]
        var docs: [DocID: Doc] = [:]
        var owners: [Int: [DocID: Int]] = [:]   // for each connection, the docs it opened and how many times
        var started: [Key: Date] = [:]   // a broken server isn't started again on every open
        var closed = false   // set once the daemon stopped them all, so a later open starts none
        var problems: [String: [Key: [CodeProblem]]] = [:]   // by the path a tab opened the file under, then by server
        var problemsChanged: (@Sendable (String) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How long a server that broke waits before it is started again, so it isn't restarted on every open.
    let retryDelay: TimeInterval
    /// How long a server with no open file keeps running (a tab closed and opened again doesn't restart it).
    let idleDelay: TimeInterval

    let store: Store   // who trusted which project (`lsp.trusted`, written by Kelp's window)
    let remotes: Remotes
    /// Where files are read for an answer (the lines of references), so the reads never run on the cooperative pool.
    let offloads: Slots
    /// The model servers on this Mac the editor's gray text comes from (`editor.suggest`), beside the code's servers.
    let models: LocalModels
    /// The llama-server it starts for the next edit (`editor.nextEdit`), noted in the daemon's home.
    let nextEdit: NextEditServer

    /// `retryDelay` sets when a broken server restarts, and `idleDelay` when an idle one stops. Tests shorten both.
    init(
        store: Store, remotes: Remotes, offloads: Slots, clients: Clients, retryDelay: TimeInterval,
        idleDelay: TimeInterval, home: URL
    ) {
        models = LocalModels(clients: clients)
        nextEdit = NextEditServer(notes: home)
        self.store = store
        self.remotes = remotes
        self.offloads = offloads
        self.retryDelay = retryDelay
        self.idleDelay = idleDelay
    }

    func open(conn: Int, _ request: LSPOpen) {
        let key = Key(
            root: request.root, argv: [request.command] + (request.args ?? []), options: request.options,
            settings: request.settings)
        let id = DocID(key: key, path: request.path)
        let launch = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            let new = Doc(languageId: request.languageId, order: request.rank ?? 0, count: 0, text: request.text)
            state.docs[id, default: new].count += 1
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
            default:   // No server yet, or it died. A new one gets every file open for it, as last sent.
                if let at = state.started[key], Date().timeIntervalSince(at) < retryDelay { return false }
                state.started[key] = Date()
                let others = state.docs.filter { $0.key != id && $0.key.key == key }.flatMap { other, doc in
                    Array(
                        repeating: DocOp.open(path: other.path, text: doc.text, languageId: doc.languageId),
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
        state.withLock { state in
            for id in state.docs.keys.filter({ $0.path == path && $0.key.root == root }) {
                state.docs[id]?.text = text
                Self.send(.change(path: path, text: text), to: id.key, in: &state)
            }
        }
    }

    /// Sets `changed`, which is called with a file's path when the file's problems are new. It is set once.
    func whenProblemsChange(_ changed: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.problemsChanged = changed }
    }

    /// The file's problems from every server, top to bottom.
    func problems(_ path: String) -> [CodeProblem] {
        state.withLock { $0.problems[path] ?? [:] }.values.joined().sorted {
            ($0.line, $0.column, $0.message) < ($1.line, $1.column, $1.message)
        }
    }

    /// Takes a server's problems for a file. A server may name a file by its real path (/private/tmp), and a tab by the
    /// path it was given. Problems are kept only for a file open in a tab, because a server may report on the whole
    /// project, and the next open is told again. The paths are resolved outside the lock, because opens and changes
    /// take that lock on a connection's reader thread.
    private func heard(_ key: Key, _ reported: String, _ found: [CodeProblem]) {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let open = state.withLock { s in Set(s.docs.keys.filter { $0.key == key }.map(\.path)) }
        let target = real(reported)
        guard let path = open.contains(reported) ? reported : open.first(where: { real($0) == target }) else { return }
        let changed = state.withLock { state -> (@Sendable (String) -> Void)? in
            guard state.docs[DocID(key: key, path: path)] != nil else { return nil }   // the file was closed meanwhile
            state.problems[path, default: [:]][key] = found.isEmpty ? nil : found
            if state.problems[path]?.isEmpty == true { state.problems[path] = nil }
            return state.problemsChanged
        }
        changed?(path)
    }

    /// Closes the file at each of its servers, because a tab on it closed.
    func close(conn: Int, _ root: String, _ path: String) {
        let ids = state.withLock { state in
            (state.owners[conn] ?? [:]).keys.filter { $0.path == path && $0.key.root == root }
        }
        ids.forEach { close(conn: conn, $0) }
    }

    private func close(conn: Int, _ id: DocID) {
        let idle = state.withLock { state -> Key? in
            // Nothing to do for a file that this connection didn't open.
            guard let opens = state.owners[conn]?[id], opens > 0, var doc = state.docs[id] else { return nil }
            state.owners[conn]?[id] = opens > 1 ? opens - 1 : nil
            if state.owners[conn]?.isEmpty == true { state.owners[conn] = nil }
            doc.count -= 1
            state.docs[id] = doc.count > 0 ? doc : nil
            if doc.count == 0 {   // the file's last tab, of any connection, closed
                state.problems[id.path]?[id.key] = nil
                if state.problems[id.path]?.isEmpty == true { state.problems[id.path] = nil }
            }
            Self.send(.close(path: id.path), to: id.key, in: &state)
            return state.docs.keys.contains { $0.key == id.key } ? nil : id.key
        }
        if let idle { stopLater(idle) }
    }

    /// Closes everything that a connection opened, once the connection is gone.
    func closeAll(conn: Int) {
        for (id, opens) in state.withLock({ $0.owners[conn] ?? [:] }) {
            for _ in 0..<opens { close(conn: conn, id) }
        }
    }

    /// Returns an open file's servers in their order, each as a running client or as the task of one still starting.
    private func servers(_ root: String, _ path: String) -> [(LSPClient?, Task<LSPClient?, Never>?)] {
        state.withLock { state in
            state.docs.filter { $0.key.path == path && $0.key.key.root == root }
                .sorted { $0.value.order < $1.value.order }
                .map { id, _ in
                    switch state.servers[id.key] {
                    case .running(let client)?: (client.isRunning ? client : nil, nil)
                    case .starting(_, let ready)?: (nil, ready)
                    default: (nil, nil)
                    }
                }
        }
    }

    /// Returns the running servers of an open file, in their order, after waiting for those that are starting.
    func clients(_ root: String, _ path: String) async -> [LSPClient] {
        var up: [LSPClient] = []
        for (running, ready) in servers(root, path) {
            if let running { up.append(running) } else if let started = await ready?.value { up.append(started) }
        }
        return up
    }

    /// Returns the server that answers a question about an open file. That is the first of its servers that said it
    /// can (`hoverProvider`…), without waiting for those after it, or the first of all when none said so. Returns nil
    /// when none runs.
    func client(_ root: String, _ path: String, can capability: String) async -> LSPClient? {
        var first: LSPClient?
        for (running, ready) in servers(root, path) {
            var client = running
            if client == nil { client = await ready?.value }
            guard let client else { continue }
            if client.can(capability) { return client }
            first = first ?? client
        }
        return first
    }

    /// Returns, for each of `commands` in `root` (or in every project when `root` is nil), whether a server of it runs
    /// or is starting, how many files are open at it, and whether one didn't start or died.
    func states(_ root: String?, _ commands: [String]) -> [String: (running: Bool, files: Int, failed: Bool)] {
        state.withLock { state in
            var all: [String: (running: Bool, files: Int, failed: Bool)] = [:]
            for (key, server) in state.servers where root == nil || key.root == root {
                guard let command = key.argv.first, commands.contains(command) else { continue }
                var one = all[command] ?? (false, 0, false)
                switch server {
                case .running(let client) where client.isRunning: one.running = true
                case .starting: one.running = true
                default: one.failed = true
                }
                one.files += state.docs.keys.count { $0.key == key }
                all[command] = one
            }
            return all
        }
    }

    /// Stops the servers of `command` in `root` and starts them again, each with the files open at it as last sent. A
    /// server that is still starting is left alone, and one with no file open is dropped instead.
    func restart(_ root: String, _ command: String) {
        let (old, again, paths, changed) = state.withLock { state in
            var old: [LSPClient] = [], again: [Key] = [], paths: Set<String> = []
            for (key, server) in state.servers where key.root == root && key.argv.first == command {
                if case .starting = server { continue }
                if case .running(let client) = server { old.append(client) }
                let docs = state.docs.filter { $0.key.key == key }
                for id in docs.keys where state.problems[id.path]?.removeValue(forKey: key) != nil {
                    paths.insert(id.path)   // the new server reports them again
                }
                state.started[key] = docs.isEmpty ? nil : Date()
                guard !docs.isEmpty else {
                    state.servers[key] = nil
                    continue
                }
                let opens = docs.flatMap { id, doc in
                    Array(
                        repeating: DocOp.open(path: id.path, text: doc.text, languageId: doc.languageId),
                        count: doc.count)
                }
                state.servers[key] = .starting(pending: opens, ready: nil)
                again.append(key)
            }
            return (old, again, paths, state.problemsChanged)
        }
        old.forEach { $0.terminate() }
        again.forEach(start)
        paths.forEach { changed?($0) }
    }

    /// Stops every server, because the daemon is stopping.
    func stopAll() {
        let all = state.withLock { state in
            state.closed = true
            defer { state.servers = [:] }
            return state.servers.values.compactMap { if case .running(let client) = $0 { client } else { nil } }
        }
        // The servers are gone before this returns, because the daemon stops or execs next, and a SIGKILL left for
        // later would never come.
        DispatchQueue.concurrentPerform(iterations: all.count) { all[$0].terminateNow() }
        nextEdit.stop(now: true)
    }

    private func start(_ key: Key) {
        let ready = Task.detached { [self] () -> LSPClient? in
            // The client is made on a thread of its own, because a cold login-shell PATH (LoginPath) takes up to 8 s,
            // too long to hold a pool thread. It is handed over under a lock, because the Thread Sanitizer doesn't see
            // that resuming the continuation from that thread orders the client's init before its use here. It
            // reported the client's fields as raced.
            let made = OSAllocatedUnfairLock<LSPClient?>(initialState: nil)
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    let client = LSPClient(
                        argv: key.argv, root: key.root, options: key.options, settings: key.settings
                    ) { [weak self] path, found in
                        self?.heard(key, path, found)
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
            stopLater(key)   // the server may have started only to close a file
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

    /// Runs under the host's lock. The client's own lock is taken inside the host's lock, never the other way round.
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
                guard !state.docs.keys.contains(where: { $0.key == key }),
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
