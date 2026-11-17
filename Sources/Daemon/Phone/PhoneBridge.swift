import Core
import CryptoKit
import Foundation
import SystemConfiguration
import os

/// The agents on a phone (Settings › Phone; off until `phone.relay` has an address). The phone opens the relay's page,
/// and the relay passes its calls to the connection this Mac keeps open to it, so no Mac needs an address of its own.
/// It lives in the daemon, so it works with Kelp's window closed, and its calls are answered as the daemon's own
/// (`Asker`), which count as the user's, as a phone's Allow has to.
///
/// Unlike ntfy's channel (PhonePush.swift), whose address is its only secret and which therefore only sends news, a
/// phone here also answers. Each phone holds a key from its pairing link that the relay never sees, every call is
/// sealed under that key (`PhoneSeal`), and no call counts twice (`PhoneDevice.admit`). The relay can read which Mac
/// and which phone a call is for, and nothing else. Limit: the page itself comes from the relay, so a relay that served
/// a different page could take a key.
actor PhoneBridge {
    /// A method of the daemon's, answered as a call of its own: its name and params, the result as JSON.
    typealias Asker = @Sendable (String, JSONValue) async throws -> Data
    /// What the daemon tells it, in the order it happened (`hear`).
    enum News: Sendable {
        case started(Asker), settings, session(Session), removed(String), stop
        case push(title: String, body: String, agent: String)
    }

    let store: Store, settings: SettingsStore, setup: SessionSetup, live: SessionTable
    /// Where the agents keep their conversations, what waits on a disk or a program, and Kelp's home.
    let conversations: Conversations, offloads: Slots, root: URL
    private let news: AsyncStream<News>.Continuation
    /// Whether any phone takes pushes, for `ExtensionEvents`, which asks from its own queue.
    private let pushes = OSAllocatedUnfairLock(initialState: false)
    let http = URLSession(configuration: .ephemeral)
    var asker: Asker?   // while the daemon serves

    struct Relay: Equatable {
        var base: URL, mac: String, secret: String
        func request(_ path: String, timeout: TimeInterval) -> URLRequest {
            var request = URLRequest(
                url: base.appendingPathComponent("mac/\(mac)/\(path)"), timeoutInterval: timeout)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            return request
        }
    }
    /// An event stream a phone holds open: its lines go out one at a time, in order, to the relay or down the phone's
    /// own connection to this Mac. `end`: the phone is told it's over (`telling`), and nothing more is written.
    struct Stream {
        var device: String, key: SymmetricKey, number: Int64, sent = 0
        var write: @Sendable (String) -> Void = { _ in }
        var end: @Sendable (_ telling: Bool) -> Void = { _ in }
    }
    /// How a phone reaches this Mac (`phone.via`): through a relay, or straight to the page kelpd serves itself, over
    /// Tailscale or at an address of the user's own.
    enum Way: Equatable {
        case relay(URL)
        case tailscale(port: Int)
        case address(String?, port: Int)
        var name: String {
            switch self {
            case .relay: "relay"
            case .tailscale: "tailscale"
            case .address: "address"
            }
        }
    }
    var way: Way?   // nil: off
    private var relay: Relay?
    private var following: Task<Void, Never>?
    var server: PhoneServer?
    /// This Mac's name in its tailnet once Tailscale serves the page ("https://mac.tail1234.ts.net:8443").
    var tailnet: String?
    /// Tailscale's steps as last looked, while it's the way.
    var tailscaleSteps: TailscaleSteps?
    var connected = false, failure: String?
    private var record: PhoneRecord?
    var devices: [String: PhoneDevice] = [:]
    var pairing: (key: SymmetricKey, link: String, until: Date)?
    var streams: [String: Stream] = [:]
    /// The agents as the phones were last told.
    var shown: [String: [String: JSONValue]] = [:]
    /// Each project's icon file by its folder, nil for none, and when it was looked for (PhoneBridge+Projects.swift).
    var iconFiles: [String: (file: String?, found: Date)] = [:]

    init(
        store: Store, settings: SettingsStore, setup: SessionSetup, live: SessionTable, conversations: Conversations,
        offloads: Slots, root: URL
    ) {
        self.conversations = conversations
        self.offloads = offloads
        self.root = root
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
    /// The way Settings › Phone names. Nothing chosen but a relay's address there: a relay, as Kelp 0.14 kept it.
    private func wanted() -> Way? {
        let port = Int(settings[SettingKeys.phonePort])
        let relay = PhonePush.url(settings[SettingKeys.phoneRelay])
        switch settings[SettingKeys.phoneVia] {
        case "tailscale": return .tailscale(port: port)
        case "address":
            return .address(PhonePush.url(settings[SettingKeys.phoneAddress])?.absoluteString, port: port)
        case "relay": return (relay ?? URL(string: SettingKeys.phoneRelayAddress)).map(Way.relay)
        default: return relay.map(Way.relay)
        }
    }

    /// Follows Settings › Phone: the relay's connection or this Mac's own server, and nothing once the setting is off
    /// or the daemon stops.
    private func apply() {
        let want = asker == nil ? nil : wanted()
        guard want != way else { return }
        following?.cancel()
        following = nil
        server?.stop()
        server = nil
        cut(streams.keys)
        if case .tailscale = way { PhoneTailscale.stopServing(offloads) }
        (way, relay, connected, failure, pairing, shown, tailnet) = (nil, nil, false, nil, nil, [:], nil)
        tailscaleSteps = nil
        guard let want, let identity = load() else { return }
        way = want
        for session in sessions() where PhoneAgent.shown(session) { shown[session.id] = agent(session) }
        switch want {
        case .relay(let base):
            let relay = Relay(base: base, mac: identity.mac, secret: identity.secret)
            self.relay = relay
            following = Task { await follow(relay) }
        case .tailscale(let port):
            serve(port)
            following = Task { await followTailscale(port) }
        case .address(_, let port): serve(port)
        }
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

    func remember() {
        guard var record else { return }
        record.devices = devices.mapValues(\.kept)
        self.record = record
        for id in devices.keys { devices[id]?.wasSaved() }
        let takes = devices.values.contains { $0.push != nil }
        pushes.withLock { $0 = takes }
        Log.session.attempt("keeping the phones") { try store.setDaemonState(PhoneRecord.key, record) }
    }

    func forget(_ device: String) {
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
            linkUntil: pairing?.until, via: way?.name, address: address, tailscale: tailscaleSteps,
            phones: devices.map { PairedPhone(id: $0.key, name: $0.value.name, push: $0.value.push != nil) }
                .sorted { ($0.name, $0.id) < ($1.name, $1.id) })
    }

    /// The link carries a key, for one phone and ten minutes. The phone that seals "pair" with it keeps it.
    func pair() throws -> PhoneState {
        guard way != nil, let mac = record?.mac else { throw RPCError.invalidParams("Turn Phone on first.") }
        guard let address else {
            throw RPCError.invalidParams(failure ?? "Kelp doesn't know yet at what address a phone finds this Mac.")
        }
        let key = PhoneSeal.random(32)
        pairing = (
            SymmetricKey(data: key), "\(address)/#pair=\(mac).\(key.base64URL)", Date().addingTimeInterval(600)
        )
        return state()
    }

    /// Where a phone opens the page: the relay, this Mac's name in its tailnet, or the address the user gave.
    private var address: String? {
        let found: String? =
            switch way {
            case .relay(let base): base.absoluteString
            case .tailscale: tailnet
            case .address(let address, _): address
            case nil: nil
            }
        return found?.trimmingCharacters(in: ["/"])
    }

    func unpair(_ device: String) -> PhoneState {
        forget(device)
        return state()
    }
}

// MARK: - Agents

extension PhoneBridge {
    /// A method of the daemon's, asked as the user.
    func call<Method: RPCMethod>(_ method: Method) async throws -> Method.Result {
        guard let asker else { throw RPCError.internalError("The Mac is not answering.") }
        let result = try await asker(Method.name, try method.params() ?? .null)
        return try JSONDecoder().decode(Method.Result.self, from: result)
    }

    static var macName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }

    func sessions() -> [Session] {
        (Log.session.attempt("reading the sessions") { try store.sessions() } ?? []).map { live[$0.id]?.snapshot ?? $0 }
    }
    func session(_ id: String) -> Session? {
        live[id]?.snapshot ?? (Log.session.attempt("reading a session") { try store.session(id) } ?? nil)
    }

    func agent(_ session: Session) -> [String: JSONValue] {
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
            session, name: name, project: repo?.name ?? "", projectId: repo?.id,
            workspace: worktree?.displayName ?? "")
    }

    /// A session's saved change: the phones hear of an agent that looks different now, or went.
    private func tell(_ session: Session) {
        guard way != nil else { return }
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
    func vapid() -> P256.Signing.PrivateKey? {
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
        guard way != nil, !to.isEmpty, let key = vapid() else { return }
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
