import AgentData
import Agents
import Core
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import Daemon

// The phone bridge: the envelope as the page seals it, no call twice, a push as RFC 8291 seals one, a session as the
// page's agent, and a phone's calls from pairing to Allow.

private func key(_ text: String) throws -> SymmetricKey { SymmetricKey(data: try #require(Data(base64URL: text))) }
private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// kelp_lending's relay/vectors.json: boxes Node sealed (mock/server.mjs `seal`).
@Test func boxesNodeSealedOpen() throws {
    let key = try key("BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc")
    let asked: PhoneBridge.Ask = try PhoneSeal.open(
        "mL5BiWc0_hy6QJcwHPsC7sXLLMQgJ9g-BOWfvcnNMxKaV_N3yDMYX836zxZ0dk0VUNmvATRdtoQ1mt7HFnqcv25F1vR4BXJEQrHKQes14qYGD3KQ348GA0adR4fWyRM1eTGbjU8eIgI5Yk9m-JYQejKZvtT-42KMos6xKZMp-uS7s0mHADp42nHgggQ6UI4T2KX4NIuuIjZNlmMs05A",
        about: "q", key: key)
    #expect(asked.n == 7_357_000_000_000_001 && asked.method == "POST" && asked.path == "agents/a%20b/choose")
    #expect(asked.body == (try json(#"{"answer":"allow","question":"Allow Bash: swift test?"}"#)))
    let answered: PhoneBridge.Reply = try PhoneSeal.open(
        "aGxSJMprXKKVvuKfUCKsChbE0o-nFYVx9dLUuSz2f83wnRt_X_i4TbVfty5zHTjeRZqniMUWp6uxtj_CGQ",
        about: "r7357000000000001", key: key)
    #expect(answered == PhoneBridge.Reply(status: 200, body: try json(#"{"ok":true}"#)))
    let event: JSONValue = try PhoneSeal.open(
        "Buvnh8_TW93_C61NHeNWfpHcDrfKJVTtW32EB3vTbbvCqMop41CIaGY0mb-k1j_Clmmz68-N_GaQHjHP6fxolSMqWGW_aAra_ehzRNYcnWompP3PsgSfmHi081USTV6yrcV8VQ-E-sLPCu31oYwG2bj7CYc",
        about: "e7357000000000001.0", key: key)
    #expect(event == (try json(#"{"event":"agent","data":{"id":"perm","title":"Привет, мир","status":"waiting"}}"#)))
}

/// What's sealed says which way it goes: an answer doesn't open as a request, nor under another key, nor changed.
@Test func aBoxOpensOnlyAsWhatItWasSealedAs() throws {
    let key = SymmetricKey(size: .bits256), reply = PhoneBridge.Reply(status: 204)
    let box = try PhoneSeal.seal(reply, about: "r5", key: key)
    let bytes = try #require(Data(base64URL: box))
    #expect(bytes.count == 12 + #"{"status":204}"#.utf8.count + 16)   // nonce, the JSON, tag: as Node's side reads it
    #expect(try PhoneSeal.open(box, about: "r5", key: key) == reply)
    #expect(throws: (any Error).self) { let _: PhoneBridge.Reply = try PhoneSeal.open(box, about: "r6", key: key) }
    #expect(throws: (any Error).self) { let _: PhoneBridge.Reply = try PhoneSeal.open(box, about: "q", key: key) }
    #expect(throws: (any Error).self) {
        let _: PhoneBridge.Reply = try PhoneSeal.open(box, about: "r5", key: SymmetricKey(size: .bits256))
    }
    var bent = bytes
    bent[20] ^= 1
    #expect(throws: (any Error).self) {
        let _: PhoneBridge.Reply = try PhoneSeal.open(bent.base64URL, about: "r5", key: key)
    }
    #expect(throws: (any Error).self) { let _: PhoneBridge.Reply = try PhoneSeal.open("x", about: "r5", key: key) }
}

@Test func noNumberCountsTwice() {
    let now = Double(Int64(Date().timeIntervalSince1970 * 1000) * 4096)
    var phone = PhoneDevice(key: SymmetricKey(size: .bits256), name: "A")
    func admit(_ number: Double) -> Bool { phone.admit(number) }
    #expect(admit(now))
    #expect(!admit(now), "the same call twice")
    #expect(admit(now + 1) && admit(now - 1), "a later one, and one that arrived late")
    #expect(!admit(now - Double(PhoneDevice.window)), "more than five minutes behind the newest")
    #expect(!admit(0) && !admit(-1) && !admit(1.5) && !admit(.nan) && !admit(1e300))
    phone.wasSaved()   // a phone is written down as it pairs
    #expect(!phone.needsSaving)
    #expect(admit(now + Double(PhoneDevice.second) + 2) && phone.needsSaving)
    phone.wasSaved()
    #expect(!phone.needsSaving)
}

/// After a restart the seen numbers are forgotten: nothing passes that could have been seen, which is the newest
/// written down and a second over it.
@Test func afterARestartNothingPassesThatCouldHaveBeenSeen() throws {
    let key = SymmetricKey(size: .bits256), saved: Int64 = 7_000_000_000_000_000
    var phone = PhoneDevice(key: key, kept: PhoneKept(name: "A", last: saved, push: nil))
    func admit(_ number: Double) -> Bool { phone.admit(number) }
    #expect(!admit(Double(saved)) && !admit(Double(saved + 5)))
    #expect(!admit(Double(saved + PhoneDevice.second)))
    #expect(admit(Double(saved + PhoneDevice.second + 1)))
    #expect(phone.kept == PhoneKept(name: "A", last: saved + PhoneDevice.second + 1, push: nil))
    let kept = try JSONDecoder().decode(PhoneKept.self, from: try JSONEncoder().encode(phone.kept))
    #expect(kept == phone.kept)
}

/// RFC 8291, Appendix A.
@Test func aPushIsSealedAsRFC8291Says() throws {
    let to = try #require(
        PushSubscription(
            try json(
                #"{"endpoint":"https://web.push.apple.com/x","keys":{"p256dh":"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4","auth":"BTBZMqHH6r4Tts7J_aSIgg"}}"#
            )))
    let mine = try P256.KeyAgreement.PrivateKey(
        rawRepresentation: try #require(Data(base64URL: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")))
    let body = try WebPush.body(
        Data("When I grow up, I want to be a watermelon".utf8), to: to, mine: mine,
        salt: try #require(Data(base64URL: "DGv6ra1nlYgDCS1FRnbzlw")))
    #expect(
        body.base64URL
            == "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    )
    #expect(try WebPush.body(Data("x".utf8), to: to) != (try WebPush.body(Data("x".utf8), to: to)))   // a new key and salt each
}

/// The push service takes the post as this Mac's: a token for that service alone, signed by the key the phone was given.
@Test func aPushIsSignedForItsService() throws {
    let key = P256.Signing.PrivateKey(), now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = try #require(URL(string: "https://fcm.googleapis.com/fcm/send/abc"))
    let header = try WebPush.authorization(for: url, key: key, now: now)
    let match = try #require(header.wholeMatch(of: /vapid t=([\w-]+)\.([\w-]+)\.([\w-]+), k=([\w-]+)/))
    #expect(Data(base64URL: String(match.4)) == key.publicKey.x963Representation)
    #expect(
        try json(String(decoding: try #require(Data(base64URL: String(match.1))), as: UTF8.self))
            == (try json(#"{"typ":"JWT","alg":"ES256"}"#)))
    #expect(
        try json(String(decoding: try #require(Data(base64URL: String(match.2))), as: UTF8.self))
            == (try json(#"{"aud":"https://fcm.googleapis.com","exp":1800043200,"sub":"https://kelpide.com"}"#)))
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64URL: String(match.3))))
    #expect(key.publicKey.isValidSignature(signature, for: Data("\(match.1).\(match.2)".utf8)))
}

/// A phone names where its pushes go: only the browsers' own push services, so it can't aim this Mac elsewhere.
@Test func onlyABrowsersPushServiceIsASubscription() throws {
    let point = Data(repeating: 4, count: 65).base64URL, auth = Data(repeating: 1, count: 16).base64URL
    func subscription(_ endpoint: String, _ p256dh: String = point, _ auth: String = auth) throws -> PushSubscription? {
        PushSubscription(try json(#"{"endpoint":"\#(endpoint)","keys":{"p256dh":"\#(p256dh)","auth":"\#(auth)"}}"#))
    }
    #expect(try subscription("https://web.push.apple.com/QGk")?.endpoint == "https://web.push.apple.com/QGk")
    #expect(try subscription("https://fcm.googleapis.com/fcm/send/a") != nil)
    #expect(try subscription("https://updates.push.services.mozilla.com/wpush/v2/a") != nil)
    #expect(try subscription("https://db5p.notify.windows.com/w/?token=a") != nil)
    #expect(try subscription("http://web.push.apple.com/a") == nil)
    #expect(try subscription("https://push.apple.com.evil.example/a") == nil)
    #expect(try subscription("https://evilpush.apple.com/a") == nil)
    #expect(try subscription("https://localhost:8080/a") == nil)
    #expect(try subscription("https://evil.example/@web.push.apple.com") == nil)
    #expect(try subscription("https://web.push.apple.com/a", Data(count: 64).base64URL) == nil)
    #expect(try subscription("https://web.push.apple.com/a", point, Data(count: 15).base64URL) == nil)
    #expect(PushSubscription(nil) == nil && PushSubscription(.object([:])) == nil)
}

/// As kelp_lending's mock/server.mjs `fromKelp` makes one of `session.list`'s record.
@Test func aSessionIsThePagesAgent() throws {
    var s = Session(
        id: "S1", worktreeId: "W", cwd: "/", command: "claude", agent: "claude", status: .waiting, unread: true,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000.25), title: "Fix the flaky sync test",
        summary: "Allow Bash: swift test --filter SyncTests?")
    s.running = "swift build"
    #expect(PhoneAgent.shown(s))
    #expect(
        JSONValue.object(
            PhoneAgent.from(s, name: "Claude Code", project: "kelp", projectId: "P", workspace: "fix/sync-retry"))
            == (try json(
                #"""
                {"id":"S1","title":"Fix the flaky sync test","agent":"claude","agentName":"Claude Code","project":"kelp",
                 "projectId":"P","workspace":"fix/sync-retry","status":"waiting","statusAt":"2027-01-15T08:00:00.250Z","unread":true,
                 "summary":"Allow Bash: swift test --filter SyncTests?",
                 "ask":{"kind":"permission","text":"Allow Bash: swift test --filter SyncTests?"},
                 "running":"swift build","limit":null,"continueAt":null}
                """#)))
    // A question cut short is answered where it shows whole, and one that asks no permission by text.
    s.summary = "Allow Bash: swift test --filter…?"
    #expect(PhoneAgent.from(s, name: "", project: "", workspace: "")["ask"]?["kind"]?.string == "question")
    s.summary = "CSV or JSON by default?"
    #expect(PhoneAgent.from(s, name: "", project: "", workspace: "")["ask"]?["kind"]?.string == "question")

    s.status = .paused
    s.title = ""
    s.limitHit = LimitHit(kind: "5-hour", resets: nil)
    s.continueAt = Date(timeIntervalSince1970: 1_800_003_600)
    let paused = PhoneAgent.from(s, name: "Claude Code", project: "", workspace: "")
    #expect(paused["status"]?.string == "hibernated" && paused["title"]?.string == "claude" && paused["ask"] == .null)
    #expect(paused["limit"] == (try json(#"{"kind":"5-hour","resets":null}"#)))
    #expect(paused["continueAt"]?.string == "2027-01-15T09:00:00.000Z")

    // The sidebar's agents: not one that ended, a terminal, a plain command, or a command under an agent.
    s.status = .exited
    #expect(!PhoneAgent.shown(s))
    #expect(!PhoneAgent.shown(Session(cwd: "/", command: "zsh", agent: "shell")))
    #expect(!PhoneAgent.shown(Session(cwd: "/", command: "npm run dev", agent: "custom")))
    var under = Session(cwd: "/", command: "claude", agent: "claude")
    under.startedBy = "S1"
    #expect(!PhoneAgent.shown(under))
}

/// A phone as the page is one (phone/js/api.js): it seals each call under the key from its pairing link.
private struct Phone {
    let bridge: PhoneBridge
    var device = PhoneSeal.random(16).base64URL
    var key: SymmetricKey
    func sent(_ method: String, _ path: String, _ body: JSONValue? = nil, n: Double) throws -> PhoneBridge.Sent {
        let ask = PhoneBridge.Ask(n: n, method: method, path: path, body: body)
        return PhoneBridge.Sent(id: "c", device: device, box: try PhoneSeal.seal(ask, about: "q", key: key))
    }
    /// The call's answer, or the status it was refused with.
    func ask(_ method: String, _ path: String, _ body: JSONValue? = nil, n: Double) async throws -> PhoneBridge.Reply {
        switch await bridge.admit(try sent(method, path, body, n: n)) {
        case .refused(let status): return PhoneBridge.Reply(status: -status)
        case .answer(let box): return try PhoneSeal.open(box, about: "r\(Int64(n))", key: key)
        case .events: return PhoneBridge.Reply(status: 200)
        case .ask(let ask, let device, _): return await bridge.answer(ask, from: device)
        }
    }
}

/// Off until Settings turns it on; then a phone pairs with the link's key, once, sees the agents and answers one.
@Test func aPhonePairsSeesTheAgentsAndAllows() async throws {
    let script =
        #"stty -icanon -echo; printf 'Do you want to proceed?\n\xe2\x9d\xaf 1. Yes\n  2. No\n'; IFS= read -rsn1 k; [[ -z "$k" ]] && echo ALLOWED; sleep 30"#
    let p = try await world(agents: [
        AgentManifest(id: "menu", name: "Menu", command: "/bin/bash", args: ["-c", script])
    ])
    defer { p.d.stop() }
    let bridge = p.d.sessions.phone
    #expect(try await p.c.call(PhoneStatus()) == PhoneState())
    await #expect(throws: RPCError.self) { _ = try await p.c.call(PhonePair()) }

    // An address nothing answers at: pairing and the calls need no relay, only its name.
    _ = try await p.c.call(SettingsSet(key: SettingKeys.phoneRelay.key, value: .string("http://127.0.0.1:9/")))
    #expect(try await waitFor { try await p.c.call(PhoneStatus()).relay != nil })
    let state = try await p.c.call(PhonePair())
    let text = try #require(state.link)
    let link = try #require(text.wholeMatch(of: /http:\/\/127\.0\.0\.1:9\/#pair=([\w-]{22})\.([\w-]{43})/))
    #expect(try #require(state.linkUntil).timeIntervalSinceNow > 590 && !state.connected)
    let phone = Phone(bridge: bridge, key: try key(String(link.2)))
    var n = Double(Int64(Date().timeIntervalSince1970 * 1000) * 4096)
    func next() -> Double {
        n += 1
        return n
    }

    #expect(try await phone.ask("GET", "agents", n: next()).status == -401, "nothing before pairing")
    #expect(
        try await Phone(bridge: bridge, key: SymmetricKey(size: .bits256)).ask("POST", "pair", n: next()).status == -401
    )
    #expect(try await phone.ask("POST", "pair", .object(["name": .string("Niko’s iPhone")]), n: next()).status == 204)
    let other = Phone(bridge: bridge, key: phone.key)
    #expect(try await other.ask("POST", "pair", n: next()).status == -401, "a pairing key works once")
    let paired = try await p.c.call(PhoneStatus())
    #expect(paired.phones == [PairedPhone(id: phone.device, name: "Niko’s iPhone", push: false)] && paired.link == nil)

    let w = try await firstWorkspace(p), s = try await p.c.call(SessionCreate(worktreeId: w.id, agent: "menu"))
    _ = try await p.c.call(SessionCreate(worktreeId: w.id, command: "cat"))   // a terminal isn't an agent
    #expect(try await waitFor(5) { try await p.c.call(SessionRead(id: s.id)).contains("2. No") })
    try #require(p.d.sessions.existing(s.id)).hook(.waiting, message: "Allow rm -rf build?", asker: "")
    let listed = try await phone.ask("GET", "agents", n: next())
    let agents = try #require(listed.body?["agents"]?.array)
    #expect(agents.map { $0["id"]?.string } == [s.id] && agents.first?["agentName"]?.string == "Menu")
    #expect(agents.first?["ask"] == .object(["kind": .string("permission"), "text": .string("Allow rm -rf build?")]))
    #expect(agents.first?["project"]?.string == p.repo.name && listed.body?["mac"]?.string?.isEmpty == false)
    #expect(try await phone.ask("GET", "agents", n: n).status == -409, "the same call twice")

    let one = try await phone.ask("GET", "agents/\(s.id)", n: next())
    #expect(one.status == 200 && one.body?["id"]?.string == s.id && one.body?["lastReply"] == .null)
    #expect(try await phone.ask("GET", "agents/nobody", n: next()).status == 404)
    #expect(try await phone.ask("GET", "nowhere", n: next()).status == 404)
    #expect(try await phone.ask("POST", "agents/\(s.id)/read", n: next()).status == 204)
    func choose(_ answer: String, _ question: String) async throws -> JSONValue? {
        try await phone.ask(
            "POST", "agents/\(s.id)/choose", .object(["answer": .string(answer), "question": .string(question)]),
            n: next()
        ).body?["ok"]
    }
    #expect(try await choose("allow", "Allow npm test?") == .bool(false), "only the question the phone showed")
    #expect(try await choose("always", "Allow rm -rf build?") == .bool(false))
    #expect(try await choose("allow", "Allow rm -rf build?") == .bool(true))
    #expect(try await waitFor(5) { try await p.c.call(SessionRead(id: s.id)).contains("ALLOWED") })

    // The page's link and phones are the user's: an agent's program gets none of it, nor watches it.
    let agent = Caller.session(s.id)
    try expectRows(
        p.d,
        [
            (agent, PhonePair(), false, "a link would answer its own questions"),
            (agent, PhoneStatus(), false, "nor the link that's shown"),
            (agent, PhoneUnpair(device: phone.device), false, "nor the user's phones"),
            (agent, WatchStart(.phone), false, "nor as Settings follows it"),
            (.user, PhonePair(), true, "the user's own")
        ])

    let push = try await phone.ask("GET", "push/key", n: next())
    #expect(Data(base64URL: try #require(push.body?["key"]?.string))?.count == 65)
    #expect(
        try await phone.ask(
            "POST", "push/subscribe", .object(["endpoint": .string("https://evil.example/")]), n: next()
        ).status == 400)

    // A restart keeps the pairing and refuses what the phone sent before it.
    p.d.stop()
    let again = try await restarted(p.root)
    defer { again.stop() }
    var back = Phone(bridge: again.sessions.phone, key: phone.key)
    back.device = phone.device
    #expect(try await waitFor { await again.sessions.phone.state().phones.count == 1 })
    #expect(try await back.ask("GET", "agents", n: n).status == -409, "what it sent before")
    #expect(try await back.ask("GET", "agents", n: n + 1).status == -409, "or could have")
    let later = n + Double(PhoneDevice.second) * 2
    #expect(try await back.ask("GET", "agents", n: later).status == 200)
    #expect(try await client(p.root).call(PhoneUnpair(device: phone.device)).phones.isEmpty)
    #expect(try await back.ask("GET", "agents", n: later + 1).status == -401)
}

/// A square (or `wide`) picture of one colour, as a PNG.
private func png(_ width: Int, _ height: Int) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.1, green: 0.6, blue: 0.4, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}
private func size(_ png: Data) -> [Int] {
    let image = CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    return [image?.width ?? 0, image?.height ?? 0]
}

/// The sidebar's icon at the phone's size: a large one drawn smaller, a small one as it is; a wordmark and what
/// isn't a picture are no icon.
@Test func aProjectsIconIsDrawnForThePhone() throws {
    #expect(size(try #require(PhoneIcon.png(from: try png(512, 512)))) == [128, 128])
    #expect(size(try #require(PhoneIcon.png(from: try png(64, 64)))) == [64, 64])
    #expect(size(try #require(PhoneIcon.png(from: try png(300, 200)))) == [128, 85])
    #expect(PhoneIcon.png(from: try png(400, 100)) == nil)
    #expect(PhoneIcon.png(from: Data("<svg/>".utf8)) == nil)
}

/// A phone that names its own key at pairing is known by that one; it sees every project in the sidebar's order with
/// its icon, starts an agent the Mac lists in a project the Mac lists, and reads a conversation's turns.
@Test func aPhoneKeepsItsOwnKeySeesProjectsAndStartsAnAgent() async throws {
    let p = try await world(agents: [AgentManifest(id: "menu", name: "Menu", command: "/bin/cat")])
    defer { p.d.stop() }
    let claude = tmp()
    p.d.agentUsage.conversations.homes.withLock { $0 = (claude, tmp()) }
    try png(512, 512).write(to: URL(fileURLWithPath: p.repo.path + "/icon.png"))
    let other = try await p.c.call("repo.add", .obj(["path": .string(try makeRepo())]), as: Repo.self)
    _ = try await p.c.call(StateSet(key: "sidebar.order", value: .array([.string(other.id)])))   // dragged first
    let bridge = p.d.sessions.phone
    _ = try await p.c.call(SettingsSet(key: SettingKeys.phoneRelay.key, value: .string("http://127.0.0.1:9/")))
    #expect(try await waitFor { try await p.c.call(PhoneStatus()).relay != nil })
    let text = try #require(try await p.c.call(PhonePair()).link)
    var phone = Phone(bridge: bridge, key: try key(String(try #require(text.split(separator: ".").last))))
    var n = Double(Int64(Date().timeIntervalSince1970 * 1000) * 4096)
    func next() -> Double {
        n += 1
        return n
    }

    let own = SymmetricKey(size: .bits256), mine = own.withUnsafeBytes { Data($0).base64URL }
    let paired = try await phone.ask(
        "POST", "pair", .object(["name": .string("C"), "key": .string(mine)]), n: next())
    #expect(paired == PhoneBridge.Reply(status: 200, body: .object(["rekeyed": .bool(true)])))
    #expect(try await phone.ask("GET", "agents", n: next()).status == -401, "the link's key is done")
    phone.key = own
    let listed = try await phone.ask("GET", "agents", n: next())
    #expect(listed.status == 200)
    #expect(
        listed.body?["projects"]
            == .array([
                .object(["id": .string(other.id), "name": .string(other.name), "icon": .bool(false)]),
                .object(["id": .string(p.repo.id), "name": .string(p.repo.name), "icon": .bool(true)])
            ]))
    // Starting agents is off until Settings says so: no kinds for the page's "+", and a start is refused.
    #expect(listed.body?["kinds"] == .array([]) && listed.body?["stops"] == .bool(true))
    let refused = try await phone.ask(
        "POST", "projects/\(p.repo.id)/agents", .object(["agent": .string("menu"), "prompt": .string("hi")]), n: next())
    #expect(refused.status == 403)
    _ = try await p.c.call(SettingsSet(key: SettingKeys.phoneStartAgents.key, value: .bool(true)))
    _ = try await p.c.call(SettingsSet(key: SettingKeys.defaultAgent.key, value: .string("menu")))
    let kinds = try #require(try await phone.ask("GET", "agents", n: next()).body?["kinds"]?.array)
    #expect(kinds.contains(.object(["id": .string("menu"), "name": .string("Menu"), "default": .bool(true)])))
    #expect(kinds.filter { $0["default"] == .bool(true) }.count == 1)
    #expect(!kinds.contains { ["shell", "custom"].contains($0["id"]?.string) })

    let icon = try await phone.ask("GET", "projects/\(p.repo.id)/icon", n: next())
    #expect(icon.body?["type"]?.string == "image/png")
    let drawn = try #require(icon.body?["data"]?.string)
    #expect(size(try #require(Data(base64Encoded: drawn))) == [128, 128])
    #expect(try await phone.ask("GET", "projects/\(other.id)/icon", n: next()).status == 404)
    #expect(try await phone.ask("GET", "projects/nobody/icon", n: next()).status == 404)

    func start(_ project: String, _ agent: String, _ prompt: String) async throws -> PhoneBridge.Reply {
        try await phone.ask(
            "POST", "projects/\(project)/agents", .object(["agent": .string(agent), "prompt": .string(prompt)]),
            n: next())
    }
    #expect(try await start(p.repo.id, "shell", "ls").status == 400, "only an agent the Mac lists")
    #expect(try await start(p.repo.id, "nobody", "ls").status == 400)
    #expect(try await start(p.repo.id, "menu", "  ").status == 400)
    #expect(try await start("nobody", "menu", "hello").status == 404, "only in a project the Mac lists")
    let started = try await start(p.repo.id, "menu", " Fix the login. ")
    let id = try #require(started.body?["id"]?.string)
    let session = try #require(try await p.c.call(SessionList()).first { $0.id == id })
    let first = try await firstWorkspace(p)
    #expect(session.agent == "menu" && session.worktreeId == first.id)
    let agents = try #require(try await phone.ask("GET", "agents", n: next()).body?["agents"]?.array)
    #expect(agents.first { $0["id"]?.string == id }?["projectId"]?.string == p.repo.id)
    #expect(try await phone.ask("GET", "agents/\(id)", n: next()).body?["turns"] == nil, "its last reply alone")
    // Stop is the user's Esc in its terminal: the agent stays.
    #expect(try await phone.ask("POST", "agents/\(id)/stop", n: next()).status == 204)
    #expect(try await p.c.call(SessionList()).first { $0.id == id }?.status != .exited)

    // A Claude Code agent's conversation, from its transcript.
    var chat = Session(
        worktreeId: session.worktreeId, cwd: p.repo.path, command: "claude", agent: "claude",
        argv: ["claude", "--session-id", "abc"])
    chat.status = .done
    try p.d.sessions.store.save(chat)
    let transcript = ClaudeHistory.folder(cwd: p.repo.path, root: claude).appendingPathComponent("abc.jsonl")
    try FileManager.default.createDirectory(
        at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"""
    {"type":"user","timestamp":"2026-11-12T05:00:00.000Z","message":{"content":"Why is it slow?"}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The loop."}]}}
    """#.write(to: transcript, atomically: true, encoding: .utf8)
    let read = try await phone.ask("GET", "agents/\(chat.id)", n: next())
    #expect(
        read.body?["turns"]
            == (try json(
                #"""
                [{"role":"user","text":"Why is it slow?","at":"2026-11-12T05:00:00.000Z"},
                 {"role":"did","text":"Read 1 file"},{"role":"agent","text":"The loop."}]
                """#)))
    #expect(read.body?["lastReply"] == .null)   // it isn't running: the turns are what there is
}

/// A Claude Code in a remote project keeps its conversation on the host: the end of the file its id names is read
/// there, the newest one for an agent started before it had an id, and nothing that isn't there.
@Test func aHostsConversationIsFoundByItsIdOrTheNewest() throws {
    let host = tmp(), project = tmp().path, real = try #require(Paths.real(project))
    let folder = host.appendingPathComponent("projects/" + real.replacing(/[^A-Za-z0-9]/, with: "-"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "old\n".write(to: folder.appendingPathComponent("aaa.jsonl"), atomically: true, encoding: .utf8)
    try "new\n".write(to: folder.appendingPathComponent("bbb.jsonl"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -60)],
        ofItemAtPath: folder.appendingPathComponent("aaa.jsonl").path)
    func read(_ path: String, _ id: String?) throws -> String {
        let script = Conversations.remoteTailScript(path: path, id: id, claude: ShellQuote.word(host.path))
        return String(
            decoding: try Subprocess.output(["/bin/sh", "-c", script], cwd: "/", timeLimit: 10), as: UTF8.self)
    }
    #expect(try read(project, "aaa") == "old\n")
    #expect(try read(project, nil) == "new\n", "no id: the newest there")
    #expect(try read(project, "ccc").isEmpty, "its own isn't written yet: not another agent's")
    #expect(try read(project, "x\"; echo pwned; \"") == "new\n", "what isn't an id names no file")
    #expect(try read("/nowhere/at/all", "aaa").isEmpty)
    #expect(try read(tmp().path, nil).isEmpty)
}

/// An agent in an SSH project: its turns and last reply come from the host (here an ssh stand-in that runs the
/// command on this Mac), and it's started with an id of its own, so its file there is known.
@Test func aRemoteProjectsConversationReachesThePhone() async throws {
    _ = localSSH
    var claude = AgentManifest(id: "claude", name: "Claude Code", command: "/bin/bash", args: ["-c", "sleep 30", "x"])
    claude.sessionIdFlag = "--session-id"
    claude.resumeIdFlag = "--resume"
    let (d, c, _) = try daemon(agents: [claude])
    defer { d.stop() }
    let there = try makeRepo(), host = tmp()
    d.agentUsage.conversations.hostClaude.withLock { $0 = ShellQuote.word(host.path) }
    let repo: Repo = try await c.call("repo.addRemote", .obj(["host": "box", "path": .string(there)]), as: Repo.self)
    let workspace = try #require(try await c.call("worktree.list", as: [Worktree].self).first { $0.repoId == repo.id })
    let session = try await c.call(SessionCreate(worktreeId: workspace.id, agent: "claude"))
    let pin = try #require(session.argv.firstIndex(of: "--session-id"))
    #expect(session.argv[pin + 1] == session.id.lowercased(), "a remote agent has its id too")

    let folder = host.appendingPathComponent(
        "projects/" + (try #require(Paths.real(there))).replacing(/[^A-Za-z0-9]/, with: "-"))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #"""
    {"type":"user","timestamp":"2026-11-12T05:00:00.000Z","message":{"content":"Why is it slow?"}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"top"}}]}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The loop."}]}}
    """#.write(to: folder.appendingPathComponent(session.id.lowercased() + ".jsonl"), atomically: true, encoding: .utf8)
    try #"{"type":"assistant","message":{"content":[{"type":"text","text":"Another agent's."}]}}"#
        .write(to: folder.appendingPathComponent("newer.jsonl"), atomically: true, encoding: .utf8)

    #expect(try await c.call(SessionLastReply(id: session.id)) == "The loop.")
    _ = try await c.call(SettingsSet(key: SettingKeys.phoneRelay.key, value: .string("http://127.0.0.1:9/")))
    #expect(try await waitFor { try await c.call(PhoneStatus()).relay != nil })
    let link = try #require(try await c.call(PhonePair()).link)
    let phone = Phone(bridge: d.sessions.phone, key: try key(String(try #require(link.split(separator: ".").last))))
    let n = Double(Int64(Date().timeIntervalSince1970 * 1000) * 4096)
    #expect(try await phone.ask("POST", "pair", n: n).status == 204)
    let read = try await phone.ask("GET", "agents/\(session.id)", n: n + 1)
    #expect(read.body?["lastReply"]?.string == "The loop.")
    #expect(
        read.body?["turns"]
            == (try json(
                #"""
                [{"role":"user","text":"Why is it slow?","at":"2026-11-12T05:00:00.000Z"},
                 {"role":"did","text":"Ran 1 command"},{"role":"agent","text":"The loop."}]
                """#)))
    // No connection to the host: nothing is dialled for a phone, and the answer is there at once.
    var down = try #require(d.remotes.of(repo.path))
    down.ssh = "/usr/bin/false"
    #expect(d.agentUsage.conversations.remoteTail(of: session, on: down) == nil)
    _ = try await c.call(SessionKill(id: session.id))   // its tmux session on the "host" ends with it
}
