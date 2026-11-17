import Foundation
import os

/// A client for the daemon socket. Requests are async. The daemon's events go to `onEvent` as their own types, decoded
/// once on the reader thread. They also go to `onNotification` as JSON, for a client that reads them by name (tests).
public final class RPCClient: Sendable {
    private let fd: Int32
    /// How long a write waits for a daemon that stopped reading before it gives up and closes the connection.
    private let sendTimeout: TimeInterval
    private struct State {
        var nextID = 1
        var pending: [Int: CheckedContinuation<Data, Error>] = [:]   // id → reply line; the caller decodes it
        var closed = false, readerDone = false
        var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
        var eventHandler: (@Sendable (any RPCEvent) -> Void)?
        var closeHandler: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Every line is written from this queue, whole and in the order it was asked for, and the fd is closed here after
    /// the last line. So the caller (often the main thread) never waits on a full socket.
    private let writer = DispatchQueue(label: "dev.kelp.rpc.write")

    /// The reader thread reads this handler, so it is kept under the lock like the rest of the state.
    public var onNotification: (@Sendable (String, JSONValue) -> Void)? {
        get { state.withLock { $0.notificationHandler } }
        set { state.withLock { $0.notificationHandler = newValue } }
    }
    /// Called on the reader thread with each of the daemon's events (`rpcEvents`), as its own type.
    public var onEvent: (@Sendable (any RPCEvent) -> Void)? {
        get { state.withLock { $0.eventHandler } }
        set { state.withLock { $0.eventHandler = newValue } }
    }
    /// When this is set after the connection already dropped, it runs at once, so a caller that installs it late is
    /// still told.
    public var onClose: (@Sendable () -> Void)? {
        get { state.withLock { $0.closeHandler } }
        set {
            let runNow = state.withLock { s -> Bool in
                s.closeHandler = newValue
                return s.readerDone
            }
            if runNow { newValue?() }
        }
    }

    /// `patience` is how long to keep retrying a full queue (`Unix.connect`). It is for callers that run while a new
    /// daemon may be taking over (an agent's hook, a terminal's attach), and other callers fail at once when nothing
    /// answers. `sendTimeout` is how long a write waits for a daemon that stopped reading, and tests set it short.
    public init(socket: String, patience: TimeInterval = 0, sendTimeout: TimeInterval = 10) throws {
        fd = try Unix.connect(socket, patience: patience)
        self.sendTimeout = sendTimeout
        // When a daemon is alive but no longer reading (hung, stopped), a write gives up instead of blocking the writer
        // forever.
        let seconds = sendTimeout.rounded(.down)
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((sendTimeout - seconds) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread { [self] in readLoop() }
    }

    deinit { close() }

    /// The daemon's pid, read from the socket, so it is known even when the daemon no longer answers.
    public var daemonPID: pid_t? { state.withLock { $0.readerDone ? nil : Unix.peerPID(fd) } }

    /// Shuts the connection now, including any writes still queued. A write blocked on a daemon that stopped reading
    /// fails, and the reader's read returns. The reader thread then has the fd closed. Closing the fd here instead
    /// could let that read land on a number already reused by a newer connection, and take that connection's replies.
    public func close() {
        // This runs under the same lock the reader holds when it sets `readerDone`, before it queues the close. So the
        // fd number still belongs to this connection here.
        state.withLock { locked in
            locked.closed = true
            if !locked.readerDone { shutdown(fd, SHUT_RDWR) }
        }
    }

    /// Waits (up to `timeout`) until everything queued is written, so a quitting app's last change reaches the daemon.
    public func flush(timeout: TimeInterval = 1) {
        let written = DispatchSemaphore(value: 0)
        writer.async { written.signal() }
        _ = written.wait(timeout: .now() + timeout)
    }

    private func readLoop() {
        var lb = LineBuffer()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buf, buf.count)
            if count < 0, errno == EINTR { continue }   // A signal interrupted the read; the connection is fine.
            if count <= 0 { break }
            for line in lb.append(Data(buf[0..<count])) {
                // A result isn't decoded here, because the caller decodes it straight from the line as its own type.
                // An event is decoded here once, as its type, and also as JSON only for `onNotification`.
                if let id = Self.resultID(line) {   // Most lines: the caller's decode is the only pass over them.
                    state.withLock { $0.pending.removeValue(forKey: id) }?.resume(returning: line)
                    continue
                }
                guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else { continue }
                if let method = envelope.method {
                    let (typed, named) = state.withLock { ($0.eventHandler, $0.notificationHandler) }
                    if let event = envelope.event { typed?(event) }
                    named?(method, (try? JSONDecoder().decode(Params.self, from: line))?.params ?? .null)
                } else if let id = envelope.id {
                    let continuation = state.withLock { $0.pending.removeValue(forKey: id) }
                    if let error = envelope.error {
                        continuation?.resume(throwing: error)
                    } else {
                        continuation?.resume(returning: line)
                    }
                }
            }
        }
        let (all, done) = state.withLock { locked in
            defer {
                locked.pending = [:]
                locked.closed = true
                locked.readerDone = true
            }
            return (locked.pending, locked.closeHandler)
        }
        writer.async { [fd] in _ = Darwin.close(fd) }   // the only close, after the last write (none is written once the reader is done)
        for (_, continuation) in all { continuation.resume(throwing: RPCError.connectionClosed) }
        done?()
    }

    /// Returns the id of a successful reply in the daemon's own layout (`{"jsonrpc":"2.0","id":7,"result":…`, as the
    /// daemon's `replyLine` writes it), read from the line's first bytes. Returns nil for anything else (an error, an
    /// event, another layout), which the reader decodes. This spares a second parse of a reply that can be megabytes
    /// long (a diff, a file list).
    static func resultID(_ line: Data) -> Int? {
        let head = Array(#"{"jsonrpc":"2.0","id":"#.utf8), tail = Array(#","result":"#.utf8)
        guard line.starts(with: head) else { return nil }
        var index = line.startIndex + head.count, id = 0, digits = 0
        while index < line.endIndex, digits < 18, case let byte = line[index], byte >= 0x30, byte <= 0x39 {
            id = id * 10 + Int(byte - 0x30)
            digits += 1
            index += 1
        }
        guard digits > 0, line[index...].starts(with: tail) else { return nil }
        return id
    }

    /// Sends a notification without waiting for a reply. Notifications are written in call order, because keystrokes
    /// must not overtake each other.
    public func notify(_ method: String, _ params: JSONValue? = nil) {
        guard !state.withLock({ $0.closed }),
            let line = try? Wire.line(RPCRequest(id: nil, method: method, params: params))
        else { return }
        write(line)
    }

    /// Queues a line for the writer (callers check `closed` first). Nothing is written once the reader is done, because
    /// the fd is closed after that and its number may belong to another connection by then.
    /// A write that gives up part way closes the connection, because the next line would be glued to half of this one.
    private func write(_ line: Data) {
        writer.async { [self] in
            if !state.withLock({ $0.readerDone }), !Unix.writeAll(fd, line, wait: min(5, sendTimeout)) { close() }
        }
    }

    /// `timeout` makes the call throw if no reply came by then. Polls use it, because one reply that never arrives
    /// would stop the loop forever.
    public func call(_ method: String, _ params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws
        -> JSONValue
    {
        try await call(method, params, timeout: timeout, as: JSONValue.self)
    }

    /// Returns the reply's line, a message with `id` and `result`. An `error` reply is thrown before it gets here. A
    /// cancelled caller stops waiting at once with `CancellationError`, and the daemon's answer, if one comes, is
    /// dropped.
    private func reply(_ method: String, _ params: JSONValue?, timeout: TimeInterval?) async throws -> Data {
        let id = state.withLock { locked in
            defer { locked.nextID += 1 }
            return locked.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // This runs under the same lock the cancel handler uses to remove the continuation. So a call cancelled
                // before this point is never added.
                let refused = state.withLock { locked -> Error? in
                    if locked.closed { return RPCError.connectionClosed }
                    if Task.isCancelled { return CancellationError() }
                    locked.pending[id] = continuation
                    return nil
                }
                if let refused {
                    continuation.resume(throwing: refused)
                    return
                }
                if let timeout {
                    // `self` is weak because every typed call has a timeout now, and the client of a dropped
                    // connection must not stay alive until they all fire.
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.state.withLock { $0.pending.removeValue(forKey: id) }?
                            .resume(throwing: RPCError.noReply(method, in: timeout))
                    }
                }
                do { write(try Wire.line(RPCRequest(id: id, method: method, params: params))) } catch {
                    state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: error)
                }
            }
        } onCancel: {
            state.withLock { $0.pending.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    public func call<T: Decodable>(
        _ method: String, _ params: JSONValue? = nil, timeout: TimeInterval? = nil, as: T.Type
    ) async throws -> T {
        try JSONDecoder().decode(ResultOf<T>.self, from: await reply(method, params, timeout: timeout)).result
    }

    /// `timeout` replaces the method's own timeout (`RPCMethod.timeout`) with a shorter one.
    public func call<M: RPCMethod>(_ method: M, timeout: TimeInterval? = nil) async throws -> M.Result {
        try await call(M.name, method.params(), timeout: timeout ?? M.timeout, as: M.Result.self)
    }
    public func notify<M: RPCMethod>(_ method: M) { notify(M.name, try? method.params()) }
}

/// A line from the daemon, decoded only as far as the reader needs. That is a reply's id and error, or a
/// notification's method and params. The params are decoded as the event's own type when the method is in
/// `rpcEvents`.
private struct Envelope: Decodable {
    private static let events = Dictionary(rpcEvents.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var id: Int?, method: String?, error: RPCError?, event: (any RPCEvent)?
    private enum Key: String, CodingKey { case id, method, params, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        // An event that doesn't decode (from a newer daemon) is dropped, because this client couldn't show it.
        if let method, let type = Self.events[method] { event = try? Self.params(type, container) }
    }
    private static func params<E: RPCEvent>(_: E.Type, _ container: KeyedDecodingContainer<Key>) throws -> E {
        try container.decode(E.self, forKey: .params)
    }
}
/// A notification's params as JSON, for `onNotification`.
private struct Params: Decodable { var params: JSONValue? }
/// A reply's result as the caller's type, decoded from the line in one pass.
private struct ResultOf<R: Decodable>: Decodable { let result: R }

extension JSONValue {
    public static func obj(_ kv: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for (key, value) in kv { fields[key] = value }
        return .object(fields)
    }
}
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
