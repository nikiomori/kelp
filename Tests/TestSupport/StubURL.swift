import Foundation

/// Answers requests to the hosts a test registered, and records what was sent. Other hosts go to the network as usual.
public final class StubURL: URLProtocol, @unchecked Sendable {
    public struct Sent: Sendable { public var method: String, path: String, auth: String?, body: String }
    nonisolated(unsafe) private static var routes: [String: (Sent) -> (Int, String)] = [:]
    nonisolated(unsafe) private static var log: [String: [Sent]] = [:]
    private static let lock = NSLock()
    private static let registered: Bool = {
        URLProtocol.registerClass(StubURL.self)
        return true
    }()

    /// `route` gets each request (`path` with its query) and answers (status, body).
    public static func serve(_ host: String, _ route: @escaping (Sent) -> (Int, String)) {
        _ = registered
        lock.withLock {
            routes[host] = route
            log[host] = []
        }
    }
    public static func sent(_ host: String) -> [Sent] { lock.withLock { log[host] ?? [] } }

    override public static func canInit(with r: URLRequest) -> Bool {
        lock.withLock { routes[r.url?.host ?? ""] != nil }
    }
    override public static func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override public func stopLoading() {}
    override public func startLoading() {
        let r = request, host = r.url?.host ?? ""
        var body = ""
        if let s = r.httpBodyStream {
            s.open()
            defer { s.close() }
            var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            body = String(decoding: data, as: UTF8.self)
        } else if let d = r.httpBody {
            body = String(decoding: d, as: UTF8.self)
        }
        let sent = Sent(
            method: r.httpMethod ?? "GET", path: (r.url?.path ?? "") + (r.url?.query.map { "?" + $0 } ?? ""),
            auth: r.value(forHTTPHeaderField: "Authorization"), body: body)
        let route = Self.lock.withLock {
            Self.log[host, default: []].append(sent)
            return Self.routes[host]
        }
        let (code, text) = route?(sent) ?? (500, "")
        let response: URLResponse =
            HTTPURLResponse(
                url: r.url ?? URL(fileURLWithPath: "/"), statusCode: code, httpVersion: nil, headerFields: nil)
            ?? URLResponse()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
