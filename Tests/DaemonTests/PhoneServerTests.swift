import Agents
import Core
import CryptoKit
import Foundation
import TestSupport
import Testing

@testable import Daemon

// The phone's page and its calls from this Mac's own server, with no relay on the way.

@Test func onlyAWholeRequestOfThePagesKindIsRead() {
    func parse(_ text: String) -> PhoneHTTP.Parsed { PhoneHTTP.parse(Data(text.utf8)) }
    #expect(
        parse("GET /app.js?v=1 HTTP/1.1\r\nHost: x\r\n\r\n")
            == .request(.init(method: "GET", path: "/app.js", body: Data())))
    #expect(
        parse("POST /api/call HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}{}trailing")
            == .request(.init(method: "POST", path: "/api/call", body: Data("{}{}".utf8))))
    #expect(parse("POST /api/call HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}") == .more, "the rest of its body")
    #expect(parse("GET / HTTP/1.1\r\nHost: x\r\n") == .more, "the rest of its head")
    #expect(parse("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .bad)
    #expect(parse("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n") == .bad)
    #expect(parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .bad)
    #expect(parse("hello\r\n\r\n") == .bad)
    #expect(parse(String(repeating: "x", count: PhoneHTTP.headLimit + 1)) == .bad)
    #expect(PhoneHTTP.response(200, json: ["box": "b"]).starts(with: Data("HTTP/1.1 200 OK\r\n".utf8)))
}

/// Tailscale's own status: this Mac's name in its tailnet, once it's connected.
@Test func tailscalesStatusNamesThisMac() {
    let running = #"{"BackendState":"Running","Self":{"DNSName":"studio.tail1234.ts.net."}}"#
    #expect(PhoneTailscale.address(status: Data(running.utf8)) == "https://studio.tail1234.ts.net:8443")
    let stopped = #"{"BackendState":"Stopped","Self":{"DNSName":"studio.tail1234.ts.net."}}"#
    #expect(PhoneTailscale.address(status: Data(stopped.utf8)) == nil)
    #expect(PhoneTailscale.address(status: Data("not json".utf8)) == nil)
}

/// A free port of localhost, for the server to take.
private func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    return Int(UInt16(bigEndian: address.sin_port))
}

/// At an address of the user's own: kelpd serves the page with its rules, pairs a phone and answers it, events
/// included, all on a port of localhost.
@Test func aPhoneTalksToThisMacsOwnServer() async throws {
    let (d, c, _) = try daemon(agents: [AgentManifest(id: "menu", name: "Menu", command: "/bin/cat")])
    defer { d.stop() }
    let port = try freePort(), base = "http://127.0.0.1:\(port)"
    _ = try await c.call(SettingsSet(key: SettingKeys.phonePort.key, value: .double(Double(port))))
    _ = try await c.call(SettingsSet(key: SettingKeys.phoneAddress.key, value: .string(base + "/")))
    _ = try await c.call(SettingsSet(key: SettingKeys.phoneVia.key, value: .string("address")))
    #expect(try await waitFor { try await c.call(PhoneStatus()).connected })
    let state = try await c.call(PhoneStatus())
    #expect(state.via == "address" && state.address == base && state.error == nil)

    let session = URLSession(configuration: .ephemeral)
    let (page, pageAnswer) = try await session.data(from: try #require(URL(string: base + "/")))
    let head = try #require(pageAnswer as? HTTPURLResponse)
    #expect(head.statusCode == 200 && String(decoding: page, as: UTF8.self).contains("<title>Kelp</title>"))
    #expect(head.value(forHTTPHeaderField: "Content-Security-Policy")?.hasPrefix("default-src 'self'") == true)
    for missing in ["/../Package.swift", "/nothing.js", "/api/agents"] {
        let (_, answer) = try await session.data(from: try #require(URL(string: base + missing)))
        #expect((answer as? HTTPURLResponse)?.statusCode == 404, "\(missing)")
    }

    let link = try #require(try await c.call(PhonePair()).link)
    #expect(link.hasPrefix(base + "/#pair="))
    let text = String(try #require(link.split(separator: ".").last))
    let key = SymmetricKey(data: try #require(Data(base64URL: text)))
    let device = PhoneSeal.random(16).base64URL
    var n = Double(Int64(Date().timeIntervalSince1970 * 1000) * 4096)
    func call(_ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> (Int, Data) {
        n += 1
        let box = try PhoneSeal.seal(
            PhoneBridge.Ask(n: n, method: method, path: path, body: body), about: "q", key: key)
        var request = URLRequest(url: try #require(URL(string: base + "/api/call")))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["mac": "x", "device": device, "box": box])
        let (data, answer) = try await session.data(for: request)
        return ((answer as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
    #expect(try await call("GET", "agents").0 == 401, "nothing before pairing")
    let (status, data) = try await call("POST", "pair", .object(["name": .string("Local")]))
    #expect(status == 200)
    let sealed = try JSONDecoder().decode([String: String].self, from: data)
    let paired: PhoneBridge.Reply = try PhoneSeal.open(try #require(sealed["box"]), about: "r\(Int64(n))", key: key)
    #expect(paired.status == 204)
    let listed = try await call("GET", "agents")
    #expect(listed.0 == 200)
    let reply: PhoneBridge.Reply = try PhoneSeal.open(
        try #require(try JSONDecoder().decode([String: String].self, from: listed.1)["box"]), about: "r\(Int64(n))",
        key: key)
    #expect(reply.body?["agents"] == .array([]) && reply.body?["stops"] == .bool(true))

    // Events: the stream opens, and an agent that starts is told down it.
    n += 1
    let opened = n
    var request = URLRequest(url: try #require(URL(string: base + "/api/call")))
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode([
        "mac": "x", "device": device,
        "box": try PhoneSeal.seal(
            PhoneBridge.Ask(n: opened, method: "GET", path: "events", body: nil), about: "q", key: key)
    ])
    let (bytes, answer) = try await session.bytes(for: request)
    #expect((answer as? HTTPURLResponse)?.statusCode == 200)
    let repo = try await c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    let workspace = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let started = try await c.call(SessionCreate(worktreeId: workspace.id, agent: "menu"))
    var heard: JSONValue?
    for try await line in bytes.lines where !line.isEmpty {
        let box = try #require(try JSONDecoder().decode([String: String].self, from: Data(line.utf8))["box"])
        heard = try PhoneSeal.open(box, about: "e\(Int64(opened)).0", key: key)
        break
    }
    #expect(heard?["event"]?.string == "agent" && heard?["data"]?["id"]?.string == started.id)

    _ = try await c.call(SessionKill(id: started.id))
    // Off: the port is let go.
    _ = try await c.call(SettingsSet(key: SettingKeys.phoneVia.key, value: .string("")))
    #expect(try await waitFor { try await c.call(PhoneStatus()).via == nil })
    await #expect(throws: (any Error).self) { _ = try await session.data(from: try #require(URL(string: base + "/"))) }
}
