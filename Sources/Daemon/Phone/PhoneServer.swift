import Core
import Foundation
import Network
import os

/// The phone's page and its calls, served by this Mac itself on a port of localhost: nobody else's server hands the
/// page out, so what a phone runs is what Kelp shipped. Only this Mac reaches the port; what brings a phone to it is
/// the user's own (Tailscale, a tunnel), and whatever does sees only sealed calls (`PhoneSeal`).
/// One request a connection, which is all a page's fetches need: the answer ends with the connection closing.
final class PhoneServer: Sendable {
    /// A phone's call: `{device, box}` as it sealed it. `events`: where an event stream's lines go, and what ends it.
    typealias Call = @Sendable (_ id: String, _ device: String, _ box: String, _ events: Events) async -> Answer
    struct Events: Sendable {
        var write: @Sendable (String) -> Void
        var end: @Sendable () -> Void
    }
    enum Answer: Sendable {
        /// Unsealed, as the relay answers: 401 a phone not paired, 409 a call seen before.
        case refused(Int)
        case box(String)
        /// The call opened an event stream: its lines come through `Events.write` until the phone leaves.
        case stream
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.kelp.phone-server")
    private let page: URL?, call: Call, left: @Sendable (String) -> Void

    /// `page`: the folder with the page's files. `left`: a connection that held stream `id` closed.
    init(port: UInt16, page: URL?, call: @escaping Call, left: @escaping @Sendable (String) -> Void) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw RPCError.invalidParams("Not a port.") }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)   // this Mac only
        listener = try NWListener(using: parameters)
        self.page = page
        self.call = call
        self.left = left
    }

    /// `failed`: the port couldn't be had (another program holds it), in the system's words.
    func start(failed: @escaping @Sendable (String) -> Void) {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { failed(error.localizedDescription) }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    // MARK: A connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A request that doesn't come whole in time holds nothing.
        let asked = OSAllocatedUnfairLock(initialState: false)
        queue.asyncAfter(deadline: .now() + 30) { if !asked.withLock({ $0 }) { connection.cancel() } }
        read(connection, Data(), asked)
    }

    private func read(_ connection: NWConnection, _ got: Data, _ asked: OSAllocatedUnfairLock<Bool>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, done, error in
            guard let self else { return connection.cancel() }
            let all = got + (data ?? Data())
            switch PhoneHTTP.parse(all) {
            case .request(let request):
                asked.withLock { $0 = true }
                self.answer(request, on: connection)
            case .more where !done && error == nil: self.read(connection, all, asked)
            default: self.send(connection, PhoneHTTP.response(400, json: ["error": "Not a request."]))
            }
        }
    }

    private func answer(_ request: PhoneHTTP.Request, on connection: NWConnection) {
        guard request.method == "POST", request.path == "/api/call" else {
            return send(
                connection,
                request.path.hasPrefix("/api/")
                    ? PhoneHTTP.response(404, json: ["error": "No such path."]) : file(request))
        }
        struct Sent: Decodable { var device: String, box: String }
        guard
            let sent = Log.session.attempt(
                "reading a phone's call", { try JSONDecoder().decode(Sent.self, from: request.body) })
        else { return send(connection, PhoneHTTP.response(400, json: ["error": "Send {mac, device, box}."])) }
        let id = "local-" + UUID().uuidString, left = left
        let events = Events(
            write: { line in connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in }) },
            end: { connection.cancel() })
        Task {
            switch await call(id, sent.device, sent.box, events) {
            case .refused(let status): self.send(connection, PhoneHTTP.response(status, json: ["error": "Refused."]))
            case .box(let box): self.send(connection, PhoneHTTP.response(200, json: ["box": box]))
            case .stream:
                connection.send(content: PhoneHTTP.streamHead, completion: .contentProcessed { _ in })
                // The phone left (or the connection broke): its stream on this side ends with it.
                self.untilClosed(connection) { left(id) }
            }
        }
    }

    private func untilClosed(_ connection: NWConnection, _ closed: @escaping @Sendable () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, error in
            if done || error != nil {
                connection.cancel()
                closed()
            } else {
                self?.untilClosed(connection, closed)
            }
        }
    }

    private func send(_ connection: NWConnection, _ response: Data) {
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// One of the page's own files: nothing outside its folder, and only the kinds a page is made of.
    private func file(_ request: PhoneHTTP.Request) -> Data {
        let path = request.path == "/" ? "/index.html" : request.path
        guard request.method == "GET", let page, !path.contains(".."), !path.contains("//"),
            let type = PhoneHTTP.types[(path as NSString).pathExtension],
            let bytes = FileManager.default.contents(atPath: page.path + path)
        else { return PhoneHTTP.response(404, json: ["error": "Not found."]) }
        return PhoneHTTP.response(200, type: type, body: bytes, page: true)
    }
}

/// As much HTTP/1.1 as the phone's page speaks: a request line, headers, a body by its Content-Length.
enum PhoneHTTP {
    struct Request: Equatable {
        var method: String, path: String, body: Data
    }
    enum Parsed: Equatable {
        case request(Request)
        case more
        case bad
    }
    /// A phone's call is at most 128 KB (the relay's limit too); headers, 16 KB.
    static let bodyLimit = 1 << 17, headLimit = 16 << 10

    static let types = [
        "html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "webmanifest": "application/manifest+json", "png": "image/png", "svg": "image/svg+xml"
    ]

    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > headLimit ? .bad : .more }
        guard end.lowerBound <= headLimit, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .bad
        }
        let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad }
        var length = 0
        for line in lines.dropFirst() {
            let field = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard field.count == 2 else { return .bad }
            if field[0].lowercased() == "content-length" {
                guard let count = Int(field[1]), count >= 0, count <= bodyLimit else { return .bad }
                length = count
            }
            if field[0].lowercased() == "transfer-encoding" { return .bad }   // the page sends none
        }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .more }
        // The path alone: a query says nothing here, and a fragment never leaves a browser.
        let path = first[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        return .request(Request(method: String(first[0]), path: path ?? "/", body: Data(body.prefix(length))))
    }

    private static let reasons = [
        200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 500: "Server Error"
    ]

    /// `page`: one of the page's files, which may load only its own (as the relay serves them).
    static func response(_ status: Int, type: String, body: Data, page: Bool = false) -> Data {
        var head = [
            "HTTP/1.1 \(status) \(reasons[status] ?? "Error")", "Content-Type: \(type)",
            "Content-Length: \(body.count)", "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
            "Connection: close"
        ]
        if page { head.append("Content-Security-Policy: default-src 'self'; img-src 'self' blob:") }
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    static func response(_ status: Int, json: [String: String]) -> Data {
        let body = Log.session.attempt("writing an answer") { try JSONEncoder().encode(json) } ?? Data("{}".utf8)
        return response(status, type: "application/json; charset=utf-8", body: body)
    }

    /// An event stream's start: lines follow until the connection closes; the first, empty, says it's open.
    static var streamHead: Data {
        let head = [
            "HTTP/1.1 200 OK", "Content-Type: application/x-ndjson", "Cache-Control: no-store",
            "X-Accel-Buffering: no", "Connection: close"
        ]
        return Data((head.joined(separator: "\r\n") + "\r\n\r\n\n").utf8)
    }

    /// The page's files, shipped beside kelpd (`Kelp_Daemon.bundle`). Found by hand, as `Paths.resource` finds Core's.
    static var page: URL? {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        let dirs = [
            Bundle.main.resourceURL, Bundle(for: Token.self).resourceURL, exe?.appendingPathComponent("../Resources"),
            exe, Bundle(for: Token.self).bundleURL.deletingLastPathComponent()   // a test bundle's build folder
        ]
        return dirs.lazy.compactMap { $0?.appendingPathComponent("Kelp_Daemon.bundle") }
            .flatMap { [$0.appendingPathComponent("phone"), $0.appendingPathComponent("Contents/Resources/phone")] }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }
    private final class Token {}
}
