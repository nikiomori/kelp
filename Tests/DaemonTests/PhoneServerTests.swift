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
    #expect(
        PhoneTailscale.address(status: Data(stopped.utf8), requireRunning: false)
            == "https://studio.tail1234.ts.net:8443")
    #expect(PhoneTailscale.address(status: Data("not json".utf8)) == nil)
}

@Test func onlyKelpsPrivateServeRouteIsManaged() throws {
    let host = "studio.tail.ts.net", target = "http://127.0.0.1:47611"
    func route(_ config: String) throws -> PhoneTailscale.Route {
        try JSONDecoder().decode(PhoneTailscale.Config.self, from: Data(config.utf8)).route(host: host, target: target)
    }
    let site =
        #""TCP":{"8443":{"HTTPS":true}},"Web":{"studio.tail.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:47611"}}}}"#
    #expect(try route("{}") == .available)
    #expect(try route(#"{"TCP":{"443":{"HTTPS":true}}}"#) == .available)
    #expect(try route("{\(site)}") == .phone)
    #expect(try route("{\(site.replacingOccurrences(of: "47611", with: "8080"))}") == .occupied)
    #expect(try route(#"{"TCP":{"8443":{"TCPForward":"127.0.0.1:8080"}}}"#) == .occupied)
    #expect(try route(#"{\#(site),"AllowFunnel":{"studio.tail.ts.net:8443":true}}"#) == .occupied)
    #expect(try route(#"{"Foreground":{"another":{\#(site)}}}"#) == .occupied)
}

private let testAddress = "https://studio.tail.ts.net:8443"

private func tailscaleFixture(_ folder: URL) throws -> URL {
    let program = folder.appendingPathComponent("tailscale")
    try """
    #!/bin/sh
    cd "$(dirname "$0")" || exit 1
    case "$*" in
      "status --json") cat status;;
      "serve status --json") cat route;;
      "serve --bg --https=8443 "*)
        touch started
        while [ -f block ]; do sleep 0.05; done
        if [ -f no-route ]; then exit 0; fi
        dst="$4"
        echo '{"TCP":{"8443":{"HTTPS":true}},"Web":{"studio.tail.ts.net:8443":{"Handlers":{"/":{"Proxy":"'"$dst"'"}}}}}' > route;;
      "serve --https=8443 --set-path=/ off") echo '{}' > route;;
      *) exit 2;;
    esac
    """.write(to: program, atomically: true, encoding: .utf8)
    #expect(chmod(program.path, 0o755) == 0)
    try Data("null".utf8).write(to: folder.appendingPathComponent("route"))
    try Data(#"{"BackendState":"Running","Self":{"DNSName":"studio.tail.ts.net."}}"#.utf8)
        .write(to: folder.appendingPathComponent("status"))
    return program
}

private func phoneBridge(_ daemon: Daemon, program: URL) -> PhoneBridge {
    PhoneBridge(
        store: daemon.store, settings: daemon.settings, setup: daemon.sessions.setup, live: daemon.sessions.live,
        conversations: daemon.agentUsage.conversations, offloads: daemon.offloads, root: daemon.sessions.root,
        permissions: daemon.sessions.permissions,
        tailscale: PhoneTailscale(store: daemon.store, executable: { program.path }))
}

@Test func switchingOffWaitsForAnInFlightTailscalePublication() async throws {
    let folder = tmp(), program = try tailscaleFixture(folder), block = folder.appendingPathComponent("block")
    let daemon = try Daemon(root: tmp()), phone = phoneBridge(daemon, program: program)
    try Data().write(to: block)
    let publishing = Task { await phone.followTailscale(47611) }
    let started = try await waitFor {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("started").path)
    }
    let registered = try daemon.store.daemonState(PhoneTailscale.ownersKey, as: [String: UInt16].self)
    #expect(registered?[testAddress] == 47611, "ownership reached disk before Serve changed")
    publishing.cancel()
    try FileManager.default.removeItem(at: block)
    await publishing.value
    #expect(started)
    let route = folder.appendingPathComponent("route")
    #expect(try String(contentsOf: route, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    #expect(try daemon.store.daemonState(PhoneTailscale.ownersKey, as: [String: UInt16].self) == nil)
}

/// A slow Tailscale doesn't hold up the daemon's stop, which saves the sessions before it waits for the route to go.
@Test func stoppingThePhoneDoesntWaitForTailscale() async throws {
    let folder = tmp(), program = try tailscaleFixture(folder), block = folder.appendingPathComponent("block")
    let (fd, port) = try boundPort()
    close(fd)
    let daemon = try Daemon(root: tmp()), phone = phoneBridge(daemon, program: program)
    _ = try daemon.settings.set(SettingKeys.phonePort.key, .int(port))
    _ = try daemon.settings.set(SettingKeys.phoneVia.key, .string("tailscale"))
    try Data().write(to: block)
    phone.hear(.started { _, _ in Data() })
    let started = folder.appendingPathComponent("started").path
    try #require(try await waitFor { FileManager.default.fileExists(atPath: started) })
    phone.stop()
    #expect(FileManager.default.fileExists(atPath: block.path), "stop returned with the route still being made")
    try FileManager.default.removeItem(at: block)
    await Task.detached { phone.waitStopped() }.value
    let route = try String(contentsOf: folder.appendingPathComponent("route"), encoding: .utf8)
    #expect(route.trimmingCharacters(in: .whitespacesAndNewlines) == "{}", "waitStopped returned once the route went")
}

@Test(arguments: [true, false]) func aRestartWithdrawsItsOldRouteEvenWhenThePhonePortIsOccupied(enabled: Bool)
    async throws
{
    let folder = tmp(), program = try tailscaleFixture(folder), root = tmp()
    let (fd, held) = try boundPort(), port = try #require(UInt16(exactly: held))
    defer { close(fd) }
    #expect(listen(fd, 1) == 0)
    do {
        let previous = try Daemon(root: root)
        let tailscale = PhoneTailscale(store: previous.store, executable: { program.path })
        _ = try tailscale.serve(port).get()   // The process ends with the publication still registered.
        _ = try previous.settings.set(SettingKeys.phonePort.key, .int(held))
        _ = try previous.settings.set(SettingKeys.phoneVia.key, .string(enabled ? "tailscale" : ""))
    }
    let daemon = try Daemon(root: root), phone = phoneBridge(daemon, program: program)
    defer { phone.stop() }
    phone.hear(.started { _, _ in Data() })
    #expect(
        try await waitFor {
            if enabled { return await phone.state().error?.contains("port \(held)") == true }
            return try daemon.store.daemonState(PhoneTailscale.ownersKey, as: [String: UInt16].self) == nil
        })
    let route = try String(contentsOf: folder.appendingPathComponent("route"), encoding: .utf8)
    #expect(route.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    #expect(try daemon.store.daemonState(PhoneTailscale.ownersKey, as: [String: UInt16].self) == nil)
}

@Test func anUnownedOrReplacedRouteIsLeftAlone() throws {
    let daemon = try Daemon(root: tmp()), folder = tmp(), program = try tailscaleFixture(folder)
    let tailscale = PhoneTailscale(store: daemon.store, executable: { program.path })
    let noRoute = folder.appendingPathComponent("no-route")
    try Data().write(to: noRoute)
    #expect(throws: PhoneTailscale.Failed.self) { try tailscale.serve(47611).get() }
    #expect(try !tailscale.withdraw())
    try FileManager.default.removeItem(at: noRoute)
    let published = try tailscale.serve(47611).get(), route = folder.appendingPathComponent("route")
    #expect(published == testAddress)
    let original = try Data(contentsOf: route), status = folder.appendingPathComponent("status")
    let previousStatus = try Data(contentsOf: status)
    try Data(#"{"BackendState":"Running","Self":{"DNSName":"other.tail.ts.net."}}"#.utf8).write(to: status)
    #expect(try tailscale.withdraw())
    #expect(try daemon.store.daemonState(PhoneTailscale.ownersKey, as: [String: UInt16].self)?[testAddress] == 47611)
    try previousStatus.write(to: status)
    let changed = Data(#"{"TCP":{"8443":{"TCPForward":"127.0.0.1:8080"}}}"#.utf8)
    try changed.write(to: route)
    #expect(try !tailscale.withdraw())
    #expect(try Data(contentsOf: route) == changed)

    try original.write(to: route)
    #expect(try tailscale.serve(47611).get() == testAddress)
    #expect(try !tailscale.withdraw())
    #expect(try Data(contentsOf: route) == original, "an identical borrowed route belongs to whoever set it up")
}

/// A route another Kelp serves now (a second Kelp home on the same port) outlives a stale record of this one's. With
/// Tailscale gone, so are its routes, and the record goes too instead of failing again every minute.
@Test func aRouteAnotherKelpServesStaysAndNoTailscaleEndsTheRecord() async throws {
    let daemon = try Daemon(root: tmp()), folder = tmp(), program = try tailscaleFixture(folder)
    let (fd, held) = try boundPort(), port = try #require(UInt16(exactly: held))
    close(fd)
    let other = try PhoneServer(
        port: port, page: PhoneHTTP.page, call: { _, _, _, _, _ in .refused(503) }, left: { _ in })
    defer { other.stop() }
    other.start { _ in }
    try #require(try await waitFor { try PhoneTailscale.kelpServes(port) })
    let tailscale = PhoneTailscale(store: daemon.store, executable: { program.path })
    _ = try tailscale.serve(port).get()
    let route = folder.appendingPathComponent("route"), served = try Data(contentsOf: route)
    #expect(try !tailscale.withdraw(leavingLiveKelp: true))
    #expect(try Data(contentsOf: route) == served)
    #expect(try daemon.store.daemonState(PhoneTailscale.ownersKey, as: [String: UInt16].self) == nil)

    try daemon.store.setDaemonState(PhoneTailscale.ownersKey, [testAddress: port])
    #expect(try !PhoneTailscale(store: daemon.store, executable: { nil }).withdraw())
    #expect(try daemon.store.daemonState(PhoneTailscale.ownersKey, as: [String: UInt16].self) == nil)
}

/// A free port of localhost, for the server to take.
private func boundPort() throws -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    guard bound == 0 else {
        close(fd)
        throw POSIXError(.EADDRINUSE)
    }
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    return (fd, Int(UInt16(bigEndian: address.sin_port)))
}

@Test func aBusyPhonePortNeverOffersAPairingLink() async throws {
    let (fd, port) = try boundPort()
    defer { close(fd) }
    #expect(listen(fd, 1) == 0)
    let (d, client, _) = try daemon()
    defer { d.stop() }
    _ = try await client.call(SettingsSet(key: SettingKeys.phonePort.key, value: .double(Double(port))))
    _ = try await client.call(SettingsSet(key: SettingKeys.phoneVia.key, value: .string("tailscale")))
    #expect(try await waitFor { try await client.call(PhoneStatus()).error?.contains("port \(port)") == true })
    let state = try await client.call(PhoneStatus())
    #expect(!state.connected && state.address == nil && state.link == nil && state.tailscale == nil)
    await #expect(throws: (any Error).self) { try await client.call(PhonePair()) }
    _ = try await client.call(SettingsSet(key: SettingKeys.phonePort.key, value: .double(1e30)))
    #expect(try await waitFor { try await client.call(PhoneStatus()).error?.contains("65535") == true })
}

/// At an address of the user's own: kelpd serves the page with its rules, pairs a phone and answers it, events
/// included, all on a port of localhost.
@Test func aPhoneTalksToThisMacsOwnServer() async throws {
    let (d, c, _) = try daemon(agents: [AgentManifest(id: "menu", name: "Menu", command: "/bin/cat")])
    defer { d.stop() }
    let (fd, port) = try boundPort(), base = "http://127.0.0.1:\(port)"
    close(fd)
    _ = try await c.call(SettingsSet(key: SettingKeys.phonePort.key, value: .double(Double(port))))
    _ = try await c.call(SettingsSet(key: SettingKeys.phoneAddress.key, value: .string(base + "/")))
    _ = try await c.call(SettingsSet(key: SettingKeys.phoneVia.key, value: .string("address")))
    #expect(try await waitFor { try await c.call(PhoneStatus()).connected })
    let state = try await c.call(PhoneStatus())
    #expect(state.via == "address" && state.address == base && state.error == nil, "\(state.error ?? "no error")")

    let session = URLSession(configuration: .ephemeral)
    let (page, pageAnswer) = try await session.data(from: try #require(URL(string: base + "/")))
    let head = try #require(pageAnswer as? HTTPURLResponse)
    #expect(head.statusCode == 200 && String(decoding: page, as: UTF8.self).contains("<title>Kelp</title>"))
    #expect(head.value(forHTTPHeaderField: "Content-Security-Policy")?.hasPrefix("default-src 'self'") == true)
    // It names its version, which the agents' list names too: a page left open through an update reloads.
    let version = try #require(PhoneHTTP.pageVersion)
    #expect(String(decoding: page, as: UTF8.self).contains(#"<meta name="kelp-page" content="\#(version)">"#))
    for missing in ["/../Package.swift", "/nothing.js", "/api/agents"] {
        let (_, answer) = try await session.data(from: try #require(URL(string: base + missing)))
        #expect((answer as? HTTPURLResponse)?.statusCode == 404, "\(missing)")
    }

    let link = try #require(try await c.call(PhonePair()).link)
    #expect(link.hasPrefix(base + "/#pair="))
    let text = String(try #require(link.split(separator: ".").last))
    var key = SymmetricKey(data: try #require(Data(base64URL: text)))
    let ownKey = PhoneSeal.random(32)
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
    let (status, data) = try await call(
        "POST", "pair", .object(["name": .string("Local"), "key": .string(ownKey.base64URL)]))
    #expect(status == 200)
    let sealed = try JSONDecoder().decode([String: String].self, from: data)
    let paired: PhoneBridge.Reply = try PhoneSeal.open(try #require(sealed["box"]), about: "r\(Int64(n))", key: key)
    #expect(paired.body?["rekeyed"] == .bool(true))
    key = SymmetricKey(data: ownKey)
    let listed = try await call("GET", "agents")
    #expect(listed.0 == 200)
    let reply: PhoneBridge.Reply = try PhoneSeal.open(
        try #require(try JSONDecoder().decode([String: String].self, from: listed.1)["box"]), about: "r\(Int64(n))",
        key: key)
    #expect(reply.body?["agents"] == .array([]) && reply.body?["stops"] == .bool(true))
    #expect(reply.body?["page"] == .string(version))

    // Events: the stream opens, and an agent that starts is told down it.
    n += 1
    let opened = n
    var request = URLRequest(url: try #require(URL(string: base + "/api/call")))
    request.httpMethod = "POST"
    request.timeoutInterval = 10 * testSlowness   // an event that never comes fails the read below, not hangs it
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

    let snapshotRevision = try #require(reply.body?["revision"]?.int)
    let eventRevision = try #require(heard?["revision"]?.int)
    #expect(eventRevision > snapshotRevision)

    _ = try await c.call(SessionKill(id: started.id))
    // Off: the port is let go.
    _ = try await c.call(SettingsSet(key: SettingKeys.phoneVia.key, value: .string("")))
    #expect(try await waitFor { try await c.call(PhoneStatus()).via == nil })
    await #expect(throws: (any Error).self) { _ = try await session.data(from: try #require(URL(string: base + "/"))) }
}
