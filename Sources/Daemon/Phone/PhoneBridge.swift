import Core
import CryptoKit
import Foundation
import SystemConfiguration
import os

/// The agents on a phone (Settings › Phone, off until `phone.relay` has an address): the phone opens the relay's page,
/// and the relay passes its calls to the connection this Mac keeps open to it, so no Mac needs an address of its own.
/// In the daemon: it works with Kelp's window closed, and its calls are answered as the daemon's own (`Asker`), which
/// are the user's, as a phone's Allow has to be.
///
/// Unlike ntfy's channel (PhonePush.swift), whose address is its only secret and which therefore only tells, a phone
/// here answers too: each holds a key from its pairing link, which the relay never sees, every call is sealed under
/// it (`PhoneSeal`) and no call counts twice (`PhoneDevice.admit`). The relay reads which Mac and which phone, and
/// nothing else. Limit: the page itself comes from the relay; one that served another page could take a key.
actor PhoneBridge {
    /// A method of the daemon's, answered as a call of its own: its name and params, the result as JSON.
    typealias Asker = @Sendable (String, JSONValue) async throws -> Data
    /// What the daemon tells it, in the order it happened (`hear`).
    enum News: Sendable {
        case started(Asker), settings, session(Session), removed(String), stop
        case push(title: String, body: String, agent: String)
    }

    private let store: Store, settings: SettingsStore, setup: SessionSetup, live: SessionTable
    private let news: AsyncStream<News>.Continuation
    /// Whether any phone takes pushes, for `ExtensionEvents`, which asks from its own queue.
    private let pushes = OSAllocatedUnfairLock(initialState: false)
    private let http = URLSession(configuration: .ephemeral)
    private var asker: Asker?   // while the daemon serves

    private struct Relay: Equatable {
        var base: URL, mac: String, secret: String
        func request(_ path: String, timeout: TimeInterval) -> URLRequest {
            var request = URLRequest(
                url: base.appendingPathComponent("mac/\(mac)/\(path)"), timeoutInterval: timeout)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            return request
        }
    }
    /// An event stream a phone holds open: its lines go out one at a time, in order.
    struct Stream {
        var device: String, key: SymmetricKey, number: Int64, sent = 0
        var lines: AsyncStream<[String: JSONValue]>.Continuation
    }
    private var relay: Relay?
    private var following: Task<Void, Never>?
    private var connected = false, failure: String?
    private var record: PhoneRecord?
    private var devices: [String: PhoneDevice] = [:]
    private var pairing: (key: SymmetricKey, link: String, until: Date)?
    private var streams: [String: Stream] = [:]
    /// The agents as the phones were last told.
    private var shown: [String: [String: JSONValue]] = [:]

    init(store: Store, settings: SettingsStore, setup: SessionSetup, live: SessionTable) {
        self.store = store
        self.settings = settings
        self.setup = setup
        self.live = live
        let (heard, news) = AsyncStream.makeStream(of: News.self)
        self.news = news
        Task { [weak self] in
            for await one in heard {
                guard let self else { return }
                await self.took(one)
            }
        }
    }

    /// From any thread; taken in the order told.
    nonisolated func hear(_ one: News) {
        news.yield(one)
        if case .stop = one { news.finish() }
    }
    nonisolated var takesPushes: Bool { pushes.withLock { $0 } }

    private func took(_ one: News) async {
        switch one {
        case .started(let asker):
            self.asker = asker
            apply()
        case .settings: apply()
        case .session(let session): tell(session)
        case .removed(let id): if shown.removeValue(forKey: id) != nil { say("removed", .object(["id": .string(id)])) }
        case .push(let title, let body, let agent): push(title: title, body: body, agent: agent)
        case .stop:
            asker = nil
            apply()
        }
    }
}

// MARK: - On and off, what's kept

extension PhoneBridge {
    /// Follows `phone.relay`: connected to the address it names, and to nothing once it's empty or the daemon stops.
    private func apply() {
        let base = asker == nil ? nil : PhonePush.url(settings[SettingKeys.phoneRelay])
        guard base != relay?.base else { return }
        following?.cancel()
        following = nil
        cut(streams.keys)
        (relay, connected, failure, pairing, shown) = (nil, false, nil, nil, [:])
        guard let base, let identity = load() else { return }
        let relay = Relay(base: base, mac: identity.mac, secret: identity.secret)
        self.relay = relay
        for session in sessions() where PhoneAgent.shown(session) { shown[session.id] = agent(session) }
        following = Task { await follow(relay) }
    }

    /// This Mac's id and secret at the relay and the phones paired before; made on the first turn-on. A Mac whose
    /// secret is gone (another keychain) is a new one to the relay, which knows an id by the secret it first came with.
    private func load() -> (mac: String, secret: String)? {
        let kept = Log.session.attempt("reading the phones") {
            try store.daemonState(PhoneRecord.key, as: PhoneRecord.self)
        }
        if let kept = kept ?? nil, let secret = Keychain.get("phone.mac") {
            record = kept
            devices = kept.devices.reduce(into: [:]) { devices, one in
                guard let key = Keychain.get("phone.device.\(one.key)").flatMap(Data.init(base64URL:)) else { return }
                devices[one.key] = PhoneDevice(key: SymmetricKey(data: key), kept: one.value)
            }
            let takes = devices.values.contains { $0.push != nil }
            pushes.withLock { $0 = takes }
            return (kept.mac, secret)
        }
        let fresh = PhoneRecord(mac: PhoneSeal.random(16).base64URL), secret = PhoneSeal.random(32).base64URL
        guard
            Log.session.attempt("keeping this Mac's phone secret", { try Keychain.set(secret, account: "phone.mac") })
                != nil
        else {
            failure = "The keychain didn't take this Mac's key."
            return nil
        }
        record = fresh
        devices = [:]
        remember()
        return (fresh.mac, secret)
    }

    private func remember() {
        guard var record else { return }
        record.devices = devices.mapValues(\.kept)
        self.record = record
        for id in devices.keys { devices[id]?.wasSaved() }
        let takes = devices.values.contains { $0.push != nil }
        pushes.withLock { $0 = takes }
        Log.session.attempt("keeping the phones") { try store.setDaemonState(PhoneRecord.key, record) }
    }

    private func forget(_ device: String) {
        guard devices.removeValue(forKey: device) != nil else { return }
        Keychain.delete("phone.device.\(device)")
        cut(streams.filter { $0.value.device == device }.keys)
        remember()
    }
}

// MARK: - Settings › Phone

extension PhoneBridge {
    func state() -> PhoneState {
        if let until = pairing?.until, until < Date() { pairing = nil }
        return PhoneState(
            relay: relay?.base.absoluteString, connected: connected, error: failure, link: pairing?.link,
            linkUntil: pairing?.until,
            phones: devices.map { PairedPhone(id: $0.key, name: $0.value.name, push: $0.value.push != nil) }
                .sorted { ($0.name, $0.id) < ($1.name, $1.id) })
    }

    /// The link carries a key, for one phone and ten minutes. The phone that seals "pair" with it keeps it.
    func pair() throws -> PhoneState {
        guard let relay else { throw RPCError.invalidParams("Turn Phone on first.") }
        let key = PhoneSeal.random(32)
        let address = relay.base.absoluteString.trimmingCharacters(in: ["/"])
        pairing = (
            SymmetricKey(data: key), "\(address)/#pair=\(relay.mac).\(key.base64URL)",
            Date().addingTimeInterval(600)
        )
        return state()
    }

    func unpair(_ device: String) -> PhoneState {
        forget(device)
        return state()
    }
}

// MARK: - The relay's client

extension PhoneBridge {
    /// What JSON or a seal made, nil with the reason in the log when it couldn't: nothing a phone can be told.
    private static func sealed<Value>(_ make: () throws -> Value) -> Value? {
        Log.session.attempt("sealing for a phone", make)
    }

    /// One line from the relay: a phone's sealed call, or its leaving a stream it held.
    struct Sent: Decodable {
        var id: String
        var device: String?
        var box: String?
        var cancel: Bool?
    }
    /// 0: it closed the connection.
    private struct Refused: LocalizedError {
        var status: Int
        var errorDescription: String? {
            switch status {
            case 0: "The relay closed the connection."
            case 401: "The relay knows this Mac by another key."
            default: "The relay answered \(status)."
            }
        }
    }

    /// Keeps the connection the relay passes calls down, coming back by itself: sooner after one that worked.
    private func follow(_ relay: Relay) async {
        var pause = 3.0
        while !Task.isCancelled {
            do {
                // The relay sends an empty line every 25 s: silence past that is a dead connection.
                let (lines, response) = try await http.bytes(for: relay.request("requests", timeout: 70))
                guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                    throw Refused(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                (connected, failure, pause) = (true, nil, 3)
                let beat = Task { await keepStreamsOpen() }
                defer { beat.cancel() }
                for try await line in lines.lines where !line.isEmpty { serve(line, relay) }
                throw Refused(status: 0)
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            connected = false
            cut(streams.keys)
            do { try await Task.sleep(for: .seconds(pause)) } catch { return }
            pause = min(pause * 2, 60)
        }
    }

    /// A proxy on the way cuts a silent connection.
    private func keepStreamsOpen() async {
        while true {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            for (id, stream) in streams { stream.lines.yield(["id": .string(id), "line": .string("\n")]) }
        }
    }

    /// Up to a call's answer everything happens here, in the order the lines came: a stream is open before the line
    /// that closes it is read.
    private func serve(_ line: String, _ relay: Relay) {
        guard let sent = Self.sealed({ try JSONDecoder().decode(Sent.self, from: Data(line.utf8)) }) else { return }
        if sent.cancel == true { return cut([sent.id], telling: false) }
        switch admit(sent) {
        case .refused(let status): post(["id": .string(sent.id), "status": .int(status)], relay)
        case .answer(let box): post(["id": .string(sent.id), "status": .int(200), "box": .string(box)], relay)
        case .events(let stream): open(stream, as: sent.id, relay)
        case .ask(let ask, let device, let key):
            Task {
                let reply = await answer(ask, from: device)
                guard let box = Self.sealed({ try PhoneSeal.seal(reply, about: "r\(Int64(ask.n))", key: key) }) else {
                    return
                }
                post(["id": .string(sent.id), "status": .int(200), "box": .string(box)], relay)
            }
        }
    }

    private nonisolated func post(_ message: [String: JSONValue], _ relay: Relay) {
        Task { await send(message, relay) }
    }

    private nonisolated func send(_ message: [String: JSONValue], _ relay: Relay) async {
        var request = relay.request("responses", timeout: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(message)
            _ = try await http.data(for: request)
        } catch {
            Log.session.error("phone relay: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func open(_ stream: Stream, as id: String, _ relay: Relay) {
        let (lines, sending) = AsyncStream.makeStream(of: [String: JSONValue].self)
        var stream = stream
        stream.lines = sending
        streams[id] = stream
        sending.yield(["id": .string(id), "stream": .bool(true)])
        Task { for await line in lines { await send(line, relay) } }
    }

    /// `telling`: the relay still holds them open (a phone that left closed its own).
    private func cut(_ ids: some Sequence<String>, telling: Bool = true) {
        for id in Array(ids) {
            guard let stream = streams.removeValue(forKey: id) else { continue }
            if telling, connected { stream.lines.yield(["id": .string(id), "end": .bool(true)]) }
            stream.lines.finish()
        }
    }

    /// An event to every phone listening: the i-th of its stream, sealed as that.
    private func say(_ event: String, _ data: JSONValue) {
        for id in Array(streams.keys) {
            guard var stream = streams[id],
                let line = Self.sealed({
                    let box = try PhoneSeal.seal(
                        ["event": .string(event), "data": data] as [String: JSONValue],
                        about: "e\(stream.number).\(stream.sent)", key: stream.key)
                    return try JSONEncoder().encode(["box": box])
                })
            else { continue }
            stream.sent += 1
            streams[id] = stream
            stream.lines.yield(["id": .string(id), "line": .string(String(decoding: line, as: UTF8.self) + "\n")])
        }
    }
}

// MARK: - A call

extension PhoneBridge {
    /// What a phone sealed: request `n` of its own, never the same twice.
    struct Ask: Codable {
        var n: Double, method: String?, path: String?, body: JSONValue?
    }
    struct Reply: Codable, Equatable {
        var status: Int
        var body: JSONValue?
        static func failed(_ status: Int, _ error: String) -> Reply {
            Reply(status: status, body: .object(["error": .string(error)]))
        }
    }
    enum Admitted {
        /// Unsealed: 401 a phone not paired or a box that doesn't open, 409 a number seen before.
        case refused(Int)
        case answer(String)
        case events(Stream)
        case ask(Ask, device: String, key: SymmetricKey)
    }

    /// The envelope: whose call it is, that it opens, that it's new; then pairing and what needs no agent.
    func admit(_ sent: Sent) -> Admitted {
        guard let id = sent.device, let box = sent.box else { return .refused(401) }
        var device: PhoneDevice, ask: Ask, fresh = false
        do {
            if let known = devices[id] {
                device = known
                ask = try PhoneSeal.open(box, about: "q", key: known.key)
            } else {
                guard let pairing, pairing.until > Date(), id.wholeMatch(of: /[\w-]{16,32}/) != nil else {
                    return .refused(401)
                }
                ask = try PhoneSeal.open(box, about: "q", key: pairing.key)
                guard ask.path == "pair" else { return .refused(401) }
                let name = ask.body?["name"]?.string ?? "Phone"
                device = PhoneDevice(key: pairing.key, name: String(name.prefix(80)))
                fresh = true
            }
        } catch { return .refused(401) }
        guard device.admit(ask.n) else { return .refused(409) }
        devices[id] = device
        if fresh {
            pairing = nil   // one phone a link
            let key = device.key.withUnsafeBytes { Data($0).base64URL }
            guard
                Log.session.attempt("keeping a phone's key", { try Keychain.set(key, account: "phone.device.\(id)") })
                    != nil
            else {
                devices[id] = nil
                return .refused(401)
            }
        }
        if fresh || device.needsSaving { remember() }
        let number = Int64(ask.n), key = device.key
        let done = Self.sealed { try PhoneSeal.seal(Reply(status: 204), about: "r\(number)", key: key) }
        switch ask.path {
        case "pair": return done.map(Admitted.answer) ?? .refused(401)
        case "unpair":
            forget(id)
            return done.map(Admitted.answer) ?? .refused(401)
        case "events":
            let (_, none) = AsyncStream.makeStream(of: [String: JSONValue].self)
            return .events(Stream(device: id, key: device.key, number: number, lines: none))
        default: return .ask(ask, device: id, key: device.key)
        }
    }

    /// A call's inside: which of the daemon's methods answers which path, asked as the user (`Asker`).
    func answer(_ ask: Ask, from device: String) async -> Reply {
        let method = ask.method ?? "GET", path = ask.path ?? "", sent = ask.body
        switch (method, path) {
        case ("GET", "agents"):
            shown = sessions().filter(PhoneAgent.shown).reduce(into: [:]) { $0[$1.id] = agent($1) }
            let agents = shown.values.sorted { ($0["statusAt"]?.string ?? "") > ($1["statusAt"]?.string ?? "") }
            return Reply(
                status: 200,
                body: .object(["mac": .string(Self.macName), "agents": .array(agents.map(JSONValue.object))]))
        case ("GET", "push/key"):
            guard let key = vapid() else { return .failed(503, "The Mac's keychain is locked.") }
            return Reply(status: 200, body: .object(["key": .string(key.publicKey.x963Representation.base64URL)]))
        case ("POST", "push/subscribe"), ("DELETE", "push/subscribe"):
            let subscription = method == "POST" ? PushSubscription(sent) : nil
            if method == "POST", subscription == nil { return .failed(400, "Not a push subscription.") }
            devices[device]?.push = subscription
            remember()
            return Reply(status: 204)
        default: break
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, parts[0] == "agents", let id = parts[1].removingPercentEncoding,
            parts.count == 2 ? method == "GET" : method == "POST" && ["choose", "reply", "read"].contains(parts[2])
        else { return .failed(404, "No such path.") }
        guard let session = session(id), PhoneAgent.shown(session) else { return .failed(404, "This agent is gone.") }
        guard let asker else { return .failed(503, "The Mac is not answering.") }
        func call<Method: RPCMethod>(_ method: Method) async throws -> Method.Result {
            let result = try await asker(Method.name, try method.params() ?? .null)
            return try JSONDecoder().decode(Method.Result.self, from: result)
        }
        do {
            switch parts.count == 3 ? parts[2] : "" {
            case "read":
                _ = try await call(SessionMarkRead(id: id))
                return Reply(status: 204)
            case "choose":
                guard let answer = sent?["answer"]?.string, ["allow", "deny"].contains(answer) else {
                    return Reply(status: 200, body: .object(["ok": .bool(false)]))
                }
                let chose = SessionChoose(id: id, answer: answer, question: sent?["question"]?.string)
                return Reply(status: 200, body: .object(["ok": .bool(try await call(chose))]))
            case "reply":
                guard let text = sent?["text"]?.string else { return .failed(400, "Send {\"text\"}.") }
                _ = try await call(SessionSend(id: id, text: text))
                return Reply(status: 204)
            default:
                var agent = agent(session)
                // Limit: the end of a reply longer than this; the relay passes a megabyte at most.
                let reply = try await call(SessionLastReply(id: id)).map { String($0.suffix(200_000)) }
                agent["lastReply"] = reply.map(JSONValue.string) ?? .null
                return Reply(status: 200, body: .object(agent))
            }
        } catch {
            return .failed(403, error.rpcMessage)   // the Mac said no: the phone shows its words
        }
    }
}

// MARK: - Agents

extension PhoneBridge {
    private static var macName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }

    private func sessions() -> [Session] {
        (Log.session.attempt("reading the sessions") { try store.sessions() } ?? []).map { live[$0.id]?.snapshot ?? $0 }
    }
    private func session(_ id: String) -> Session? {
        live[id]?.snapshot ?? (Log.session.attempt("reading a session") { try store.session(id) } ?? nil)
    }

    private func agent(_ session: Session) -> [String: JSONValue] {
        let worktree = session.worktreeId.flatMap { id in
            Log.session.attempt("reading a workspace") { try store.worktree(id) } ?? nil
        }
        let repo = worktree.flatMap { worktree in
            Log.session.attempt("reading a project") { try store.repo(worktree.repoId) } ?? nil
        }
        let name =
            Log.session.attempt("reading a manifest") {
                try setup.manifest(session.agent, command: nil, fallbackArgv: session.argv).name
            } ?? session.agent ?? ""
        return PhoneAgent.from(
            session, name: name, project: repo?.name ?? "", workspace: worktree?.displayName ?? "")
    }

    /// A session's saved change: the phones hear of an agent that looks different now, or went.
    private func tell(_ session: Session) {
        guard relay != nil else { return }
        guard PhoneAgent.shown(session) else {
            if shown.removeValue(forKey: session.id) != nil { say("removed", .object(["id": .string(session.id)])) }
            return
        }
        let agent = agent(session)
        guard shown[session.id] != agent else { return }
        shown[session.id] = agent
        say("agent", .object(agent))
    }
}

// MARK: - Push

extension PhoneBridge {
    /// This Mac's signing key for pushes, made when the first phone asks for it.
    private func vapid() -> P256.Signing.PrivateKey? {
        if let kept = Keychain.get("phone.vapid").flatMap(Data.init(base64URL:)),
            let key = Self.sealed({ try P256.Signing.PrivateKey(rawRepresentation: kept) })
        {
            return key
        }
        let key = P256.Signing.PrivateKey()
        let kept: Void? = Log.session.attempt("keeping the push key") {
            try Keychain.set(key.rawRepresentation.base64URL, account: "phone.vapid")
        }
        return kept == nil ? nil : key
    }

    /// To every phone that takes pushes; when to tell and what the words may say is `ExtensionEvents`' (PhonePush).
    private func push(title: String, body: String, agent: String) {
        let to = devices.compactMapValues(\.push)
        guard relay != nil, !to.isEmpty, let key = vapid() else { return }
        let waiting = shown.values.filter { $0["status"]?.string == AgentStatus.waiting.rawValue }.count
        let payload: [String: JSONValue] = [
            "title": .string(title), "body": .string(body), "agent": .string(agent), "waiting": .int(waiting)
        ]
        for (device, subscription) in to {
            Task {
                do {
                    let request = try WebPush.request(try JSONEncoder().encode(payload), to: subscription, vapid: key)
                    let status = (try await http.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
                    // Gone: the phone took the subscription away.
                    if status == 404 || status == 410 { unsubscribed(device, from: subscription) }
                    if status >= 400 { Log.session.error("phone push: its service answered \(status)") }
                } catch { Log.session.error("phone push: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private func unsubscribed(_ device: String, from subscription: PushSubscription) {
        guard devices[device]?.push == subscription else { return }
        devices[device]?.push = nil
        remember()
    }
}
