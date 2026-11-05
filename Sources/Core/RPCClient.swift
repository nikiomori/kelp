import Foundation
import os

/// Client for the daemon socket. Requests are async; the daemon's events go to `onEvent` as their types (decoded once, on
/// the reader thread), or to `onNotification` as JSON, for a client that reads them by name (tests).
public final class RPCClient: Sendable {
    private let fd: Int32
    private struct State {
        var nextID = 1
        var pending: [Int: CheckedContinuation<Data, Error>] = [:]   // id → its reply line, decoded by the caller as its type
        var closed = false, readerDone = false
        var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
        var eventHandler: (@Sendable (any RPCEvent) -> Void)?
        var closeHandler: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Every line goes out from here, whole and in the order it was asked for, and the fd is closed here after the last:
    /// the caller (often the main thread) never waits on a full socket.
    private let writer = DispatchQueue(label: "dev.kelp.rpc.write")

    /// Read by the reader thread, so kept under the lock like the rest.
    public var onNotification: (@Sendable (String, JSONValue) -> Void)? {
        get { state.withLock { $0.notificationHandler } }
        set { state.withLock { $0.notificationHandler = newValue } }
    }
    /// One of the daemon's events (`rpcEvents`) as its type, on the reader thread.
    public var onEvent: (@Sendable (any RPCEvent) -> Void)? {
        get { state.withLock { $0.eventHandler } }
        set { state.withLock { $0.eventHandler = newValue } }
    }
    /// Set after the connection already dropped, it runs at once: a caller that installs it late is still told.
    public var onClose: (@Sendable () -> Void)? {
        get { state.withLock { $0.closeHandler } }
        set {
            let runNow = state.withLock { s -> Bool in s.closeHandler = newValue; return s.readerDone }
            if runNow { newValue?() }
        }
    }

    /// `patience`: how long a full queue is tried again (`Unix.connect`): for a caller that runs while a daemon may be
    /// taking over (an agent's hook, a terminal's attach). The rest fail at once when nothing answers.
    public init(socket: String, patience: TimeInterval = 0) throws {
        fd = try Unix.connect(socket, patience: patience)
        // A daemon alive but no longer reading (hung, stopped): a write gives up instead of holding the writer for good.
        var t = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread { [self] in readLoop() }
    }

    deinit { close() }

    /// The daemon's pid, read from the socket: known even when it no longer answers.
    public var daemonPID: pid_t? { state.withLock { $0.readerDone ? nil : Unix.peerPID(fd) } }

    /// Shuts the connection now, what's still queued to write included: a write blocked on a daemon that stopped reading
    /// fails, and the reader's read returns. The reader thread has the fd closed after that. Closing it here could let
    /// that read land on a number already reused by a newer connection, and take its replies.
    public func close() {
        // Under the lock the reader sets `readerDone` with, before it queues the close: the number is still ours here.
        state.withLock { s in s.closed = true; if !s.readerDone { shutdown(fd, SHUT_RDWR) } }
    }

    /// Waits (up to `timeout`) until what's queued is written: a quitting app's last change must reach the daemon.
    public func flush(timeout: TimeInterval = 1) {
        let written = DispatchSemaphore(value: 0)
        writer.async { written.signal() }
        _ = written.wait(timeout: .now() + timeout)
    }

    private func readLoop() {
        var lb = LineBuffer()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EINTR { continue }   // a signal, not the end of the connection
            if n <= 0 { break }
            for line in lb.append(Data(buf[0..<n])) {
                // The result isn't read here: the caller reads it straight from the line, as its own type. An event is read
                // here, once, as its type (as JSON too only for `onNotification`).
                if let id = Self.resultID(line) {   // most lines: the caller's decode is the only pass over a big result
                    state.withLock { $0.pending.removeValue(forKey: id) }?.resume(returning: line); continue
                }
                guard let m = try? JSONDecoder().decode(Envelope.self, from: line) else { continue }
                if let method = m.method {
                    let (typed, named) = state.withLock { ($0.eventHandler, $0.notificationHandler) }
                    if let e = m.event { typed?(e) }
                    named?(method, (try? JSONDecoder().decode(Params.self, from: line))?.params ?? .null)
                } else if let id = m.id {
                    let c = state.withLock { $0.pending.removeValue(forKey: id) }
                    if let e = m.error { c?.resume(throwing: e) } else { c?.resume(returning: line) }
                }
            }
        }
        let (all, done) = state.withLock { s in
            defer { s.pending = [:]; s.closed = true; s.readerDone = true }
            return (s.pending, s.closeHandler)
        }
        writer.async { [fd] in _ = Darwin.close(fd) }   // the only close, after the last write (none is written once the reader is done)
        for (_, c) in all { c.resume(throwing: RPCError.connectionClosed) }
        done?()
    }

    /// The id of a successful reply in the daemon's own layout (`{"jsonrpc":"2.0","id":7,"result":…`, as its `replyLine`
    /// writes it), read from its first bytes; nil for anything else (an error, an event, another layout), which the
    /// reader decodes. Spares a second parse of a reply that can be megabytes (a diff, a file list).
    static func resultID(_ line: Data) -> Int? {
        let head = Array(#"{"jsonrpc":"2.0","id":"#.utf8), tail = Array(#","result":"#.utf8)
        guard line.starts(with: head) else { return nil }
        var i = line.startIndex + head.count, id = 0, digits = 0
        while i < line.endIndex, digits < 18, case let b = line[i], b >= 0x30, b <= 0x39 { id = id * 10 + Int(b - 0x30); digits += 1; i += 1 }
        guard digits > 0, line[i...].starts(with: tail) else { return nil }
        return id
    }

    /// Fire-and-forget, written in call order (keystrokes must not overtake each other).
    public func notify(_ method: String, _ params: JSONValue? = nil) {
        guard !state.withLock({ $0.closed }), let d = try? Wire.line(RPCRequest(id: nil, method: method, params: params)) else { return }
        write(d)
    }

    /// Queued for the writer (callers check `closed` first). Nothing is written once the reader is done: the fd is closed
    /// after it, and the number may be someone else's by then.
    /// A write that gives up part way closes the connection: the next line would be glued to half of this one.
    private func write(_ d: Data) { writer.async { [self] in if !state.withLock({ $0.readerDone }), !Unix.writeAll(fd, d) { close() } } }

    /// `timeout`: throw if no reply came by then — for polls, where one reply that never arrives would stop the loop for good.
    public func call(_ method: String, _ params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await call(method, params, timeout: timeout, as: JSONValue.self)
    }

    /// The reply's line: a message with `id` and `result` (or `error`, thrown before it gets here). A cancelled caller stops
    /// waiting at once, with `CancellationError`; the daemon's answer, if one comes, is dropped.
    private func reply(_ method: String, _ params: JSONValue?, timeout: TimeInterval?) async throws -> Data {
        let id = state.withLock { s in defer { s.nextID += 1 }; return s.nextID }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                // Under the lock the cancel handler takes it out with: cancelled before it's in, it never goes in.
                let refused = state.withLock { s -> Error? in
                    if s.closed { return RPCError.connectionClosed }
                    if Task.isCancelled { return CancellationError() }
                    s.pending[id] = c; return nil
                }
                if let refused { c.resume(throwing: refused); return }
                if let timeout {
                    // Weak: every typed call has one now, and a dropped connection's client mustn't wait them out.
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.state.withLock { $0.pending.removeValue(forKey: id) }?
                            .resume(throwing: RPCError.noReply(method, in: timeout))
                    }
                }
                do { write(try Wire.line(RPCRequest(id: id, method: method, params: params))) }
                catch { state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: error) }
            }
        } onCancel: {
            state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    public func call<T: Decodable>(_ method: String, _ params: JSONValue? = nil, timeout: TimeInterval? = nil, as: T.Type) async throws -> T {
        try JSONDecoder().decode(ResultOf<T>.self, from: await reply(method, params, timeout: timeout)).result
    }

    /// `timeout`: sooner than the method's own (`RPCMethod.timeout`).
    public func call<M: RPCMethod>(_ m: M, timeout: TimeInterval? = nil) async throws -> M.Result {
        try await call(M.name, m.params(), timeout: timeout ?? M.timeout, as: M.Result.self)
    }
    public func notify<M: RPCMethod>(_ m: M) { notify(M.name, try? m.params()) }
}

/// A line from the daemon as far as the reader needs it: a reply's id and error; a notification's method, and its params
/// as the event's own type when it's one of `rpcEvents`.
private struct Envelope: Decodable {
    private static let events = Dictionary(rpcEvents.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var id: Int?, method: String?, error: RPCError?, event: (any RPCEvent)?
    private enum Key: String, CodingKey { case id, method, params, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        error = try c.decodeIfPresent(RPCError.self, forKey: .error)
        // One that doesn't decode (from a newer daemon) is dropped: nothing this client could show.
        if let method, let t = Self.events[method] { event = try? Self.params(t, c) }
    }
    private static func params<E: RPCEvent>(_: E.Type, _ c: KeyedDecodingContainer<Key>) throws -> E { try c.decode(E.self, forKey: .params) }
}
/// A notification's params as JSON, for `onNotification`.
private struct Params: Decodable { var params: JSONValue? }
/// A reply's result as the caller's type, read from its line in one pass.
private struct ResultOf<R: Decodable>: Decodable { let result: R }

extension JSONValue {
    public static func obj(_ kv: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var d: [String: JSONValue] = [:]; for (k, v) in kv { d[k] = v }; return .object(d)
    }
}
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral v: Int) { self = .int(v) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}
