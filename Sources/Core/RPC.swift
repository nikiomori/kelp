import Foundation

/// JSON-RPC 2.0 messages, newline-delimited over a Unix socket.
public struct RPCRequest: Codable, Sendable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var method: String
    public var params: JSONValue?
    public init(id: Int?, method: String, params: JSONValue? = nil) {
        self.id = id; self.method = method; self.params = params
    }
}

public struct RPCError: Codable, Error, Sendable, Equatable {
    public var code: Int
    public var message: String
    /// What a program reads where `message` is for people (JSON-RPC's `data`), e.g. an `Unopenable`.
    public var data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) { self.code = code; self.message = message; self.data = data }
    public static func invalidParams(_ m: String) -> RPCError { .init(code: -32602, message: m) }
    public static func internalError(_ m: String) -> RPCError { .init(code: -32603, message: m) }
    /// Not the caller's to do (`Daemon.allow`): told apart from a bad call by `data` "refused", for tests and tools.
    public static func refused(_ m: String) -> RPCError { .init(code: -32602, message: m, data: .string("refused")) }
    public var isRefusal: Bool { data == .string("refused") }
    public static let methodNotFound = RPCError(code: -32601, message: "method not found")
    /// From a kelpd that is being replaced: the next one will answer.
    public static let updating = internalError("Kelp's background service is updating; try again in a moment.")
    /// The connection ended with no reply, or was over already.
    public static let connectionClosed = internalError("connection closed")
    public static func noReply(_ method: String, in seconds: TimeInterval) -> RPCError { internalError("no reply to \(method) in \(Int(seconds)) s") }
    public var isNoReply: Bool { message.hasPrefix("no reply to ") }
}

/// A method declared as a type (Methods.swift), shared by the app, the CLI and the daemon like Zed's proto messages:
/// a misspelled key or a wrong result shape doesn't compile. Its fields are the request's params, exactly the JSON
/// the method takes when written by hand, so untyped callers (older apps, scripts) keep working.
public protocol RPCMethod: Codable, Sendable {
    associatedtype Result: Codable & Sendable
    static var name: String { get }
    /// How long a call waits for the reply before it fails: nil waits for good (a method that takes as long as it takes).
    static var timeout: TimeInterval? { get }
}

extension RPCMethod {
    /// Past the daemon's own limit on any git, gh or ssh run (300 s, `Git.run`): only a reply that never comes ends here.
    public static var timeout: TimeInterval? { 330 }
}

extension RPCMethod {
    /// The request's params: the fields, or none for a method without any (as hand-written calls send it).
    public func params() throws -> JSONValue? {
        let p = try JSONValue.from(self)
        return p == .object([:]) ? nil : p
    }
}

/// A method for Kelp's own window and tools: `kelp schema` lists it as such, and a client of someone else's gets no promise
/// about it. Its name and shape still stay, for an older app (rpc.json).
public protocol InternalMethod: RPCMethod {}

/// The result of a method that answers null.
public struct Done: Codable, Sendable {
    public init() {}
    public init(from decoder: Decoder) {}
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encodeNil() }
}

public enum Wire {
    public static func line<T: Encodable>(_ v: T) throws -> Data {
        var d = try JSONEncoder().encode(v)
        d.append(0x0A)
        return d
    }
}

/// Accumulates bytes and yields complete newline-terminated lines.
public struct LineBuffer: Sendable {
    private var buf = Data()
    public init() {}
    /// Only the new bytes are searched and the consumed lines dropped once: a multi-MB reply arrives in 8 KB reads,
    /// and rescanning (and shifting) the whole buffer on each one was quadratic. Searched with memchr: `firstIndex(of:)`
    /// went byte by byte through Data's indices, 36 ms for a 5 MB line in a debug build.
    public mutating func append(_ d: Data) -> [Data] {
        let from = buf.count   // the bytes already here hold no newline
        buf.append(d)
        var ends: [Int] = []
        buf.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard let base = p.baseAddress else { return }
            var at = from
            while at < p.count, let hit = memchr(base + at, 0x0A, p.count - at) {
                at = base.distance(to: UnsafeRawPointer(hit)) + 1
                ends.append(at - 1)
            }
        }
        guard !ends.isEmpty else { return [] }
        let s = buf.startIndex
        var out: [Data] = [], start = 0
        for e in ends { out.append(buf[(s + start)..<(s + e)]); start = e + 1 }
        buf = Data(buf[(s + start)...])
        return out
    }
    /// Bytes waiting for their line's end.
    public var pending: Int { buf.count }
    /// Bytes received after the last complete line (a connection switching to a raw stream keeps them).
    public mutating func takeRemainder() -> Data { defer { buf = Data() }; return buf }
}
