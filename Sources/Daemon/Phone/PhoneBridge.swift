import Agents
import Core
import CryptoKit
import Foundation
import SystemConfiguration
import os

/// Shows this Mac's agents on a phone (Settings › Phone). It is off until Settings › Phone gives it a way (`Way`).
/// Through a relay, the phone opens the relay's page, and the relay passes the phone's calls down a connection that
/// this Mac keeps open to it, so the Mac needs no address of its own. The bridge lives in the daemon, so it works with
/// Kelp's window closed. It answers calls as the daemon's own (`Asker`), and those count as the user's, as a phone's
/// Allow has to.
///
/// Unlike ntfy's channel (PhonePush.swift), whose address is its only secret and which therefore only sends news, a
/// phone here also answers. Each phone holds a key from its pairing link that the relay never sees, every call is
/// sealed under that key (`PhoneSeal`), and no call counts twice (`PhoneDevice.admit`). The relay can read which Mac
/// and which phone a call is for, and nothing else. Limit: the page itself comes from the relay, so a relay that served
/// a different page could take a key.
actor PhoneBridge {
    /// Calls a daemon method as if the daemon made the call itself. It takes the method's name and params and returns
    /// the result as JSON.
    typealias Asker = @Sendable (String, JSONValue) async throws -> Data
    /// The news that the daemon sends the bridge through `hear`, taken in the order it happened.
    enum News: Sendable {
        case started(Asker), settings, reconcile, session(Session), removed(String), stop
        case push(title: String, body: String, agent: String)
    }

    let store: Store, settings: SettingsStore, setup: SessionSetup, live: SessionTable
    /// `conversations` is where the agents keep their conversations, `offloads` holds the slots for work that waits on
    /// a disk or a program, and `root` is Kelp's home.
    let conversations: Conversations, offloads: Slots, root: URL
    let permissions: PermissionWaits
    private let news: AsyncStream<News>.Continuation
    /// Whether any phone takes pushes. It sits behind a lock because `ExtensionEvents` asks from its own queue.
    private let pushes = OSAllocatedUnfairLock(initialState: false)
    let http = URLSession(configuration: .ephemeral)
    var asker: Asker?   // Set while the daemon serves.

    struct Relay: Equatable {
        var base: URL, mac: String, secret: String
        func request(_ path: String, timeout: TimeInterval) -> URLRequest {
            var request = URLRequest(
                url: base.appendingPathComponent("mac/\(mac)/\(path)"), timeoutInterval: timeout)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            return request
        }
    }
    /// An event stream that a phone holds open. Its lines go out one at a time and in order, either to the relay or
    /// down the phone's own connection to this Mac. `end` closes the stream: with `telling` set, the phone is told the
    /// stream is over. Nothing more is written after that.
    struct Stream {
        var device: String, key: SymmetricKey, number: Int64, sent = 0
        var write: @Sendable (String) -> Void = { _ in }
        var end: @Sendable (_ telling: Bool) -> Void = { _ in }
    }
    /// How a phone reaches this Mac (`phone.via`). It goes through a relay, or straight to the page that kelpd serves
    /// itself, either over Tailscale or at an address the user gives.
    enum Way: Equatable {
        case relay(URL)
        case tailscale(port: UInt16)
        case address(String?, port: UInt16)
        var name: String {
            switch self {
            case .relay: "relay"
            case .tailscale: "tailscale"
            case .address: "address"
            }
        }
    }
    var way: Way?   // nil while Phone is off
    private var relay: Relay?
    var following: Task<Void, Never>?
    let stopping = OSAllocatedUnfairLock(initialState: false)
    let publications = DispatchGroup()
    let tailscale: PhoneTailscale
    var cleanupRetry: Task<Void, Never>?, cleanupError: String?
    var server: PhoneServer?
    /// This Mac's name in its tailnet once Tailscale serves the page ("https://mac.tail1234.ts.net:8443").
    var tailnet: String?
    /// The Tailscale setup steps as last checked, while Tailscale is the way.
    var tailscaleSteps: TailscaleSteps?
    var connected = false, failure: String?
    private(set) var record: PhoneRecord?
    var devices: [String: PhoneDevice] = [:]
    var pairing: (key: SymmetricKey, link: String, until: Date)?
    var streams: [String: Stream] = [:]
    var agentRevision = 0   // Identifies which events have already reached an agents snapshot.
    /// Each agent as the phones were last told of it, by session id.
    var shown: [String: [String: JSONValue]] = [:]
    /// The icon file of each project, keyed by the project's folder, with nil when it has none, and when the file was
    /// looked for (PhoneBridge+Projects.swift).
    var iconFiles: [String: (file: String?, found: Date)] = [:]

    init(
        store: Store, settings: SettingsStore, setup: SessionSetup, live: SessionTable, conversations: Conversations,
        offloads: Slots, root: URL, permissions: PermissionWaits, tailscale: PhoneTailscale? = nil
    ) {
        self.tailscale = tailscale ?? PhoneTailscale(store: store)
        self.permissions = permissions
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

    /// Passes news to the bridge from any thread. The bridge takes the news in the order it was told.
    nonisolated func hear(_ one: News) {
        news.yield(one)
        if case .stop = one { news.finish() }
    }
    /// The process may exit or hand its instance lock to another kelpd immediately after stop returns.
    nonisolated func stop() {
        stopping.withLock { $0 = true }
        hear(.stop)
        publications.wait()
    }

    func beginPublicationWork() -> Bool {
        stopping.withLock { stopped in
            guard !stopped else { return false }
            publications.enter()
            return true
        }
    }

    func publishTailscale(_ port: UInt16) {
        guard beginPublicationWork() else { return }
        following = Task {
            defer { publications.leave() }
            await followTailscale(port)
        }
    }

    nonisolated var takesPushes: Bool { pushes.withLock { $0 } }

    private func took(_ one: News) async {
        switch one {
        case .started(let asker):
            self.asker = asker
            await apply(starting: true)
        case .settings: await apply()
        case .reconcile:
            // The active Tailscale task reconciles its current profile on each check.
            if case .tailscale = way, server != nil || following != nil { return }
            await recoverPublication()
        case .session(let change):
            if way != nil, let latest = session(change.id) { tell(latest) }
        case .removed(let id): removedAgent(id)
        case .push(let title, let body, let agent): push(title: title, body: body, agent: agent)
        case .stop:
            asker = nil
            await apply()
        }
    }
}

// MARK: - On and off, what's kept

extension PhoneBridge {
    /// Returns the way that Settings › Phone names. When no way is chosen but a relay's address is set, the way is that
    /// relay, as Kelp 0.14 stored it.
    private func wanted() -> Way? {
        let port = UInt16(exactly: settings[SettingKeys.phonePort]) ?? 0
        let relay = PhonePush.url(settings[SettingKeys.phoneRelay])
        switch settings[SettingKeys.phoneVia] {
        case "tailscale": return .tailscale(port: port)
        case "address":
            return .address(PhonePush.url(settings[SettingKeys.phoneAddress])?.absoluteString, port: port)
        case "relay": return (relay ?? URL(string: SettingKeys.phoneRelayAddress)).map(Way.relay)
        default: return relay.map(Way.relay)
        }
    }

    /// Brings the bridge in line with Settings › Phone. It runs the relay's connection or this Mac's own server, and
    /// neither once the setting is off or the daemon stops.
    private func apply(starting: Bool = false) async {
        let want = asker == nil ? nil : wanted()
        guard starting || want != way || (want == nil && failure != nil) else { return }
        cleanupRetry?.cancel()
        let previous = following, oldServer = server
        previous?.cancel()
        following = nil
        server = nil
        cut(streams.keys)
        (way, relay, connected, failure, pairing, shown, tailnet) = (nil, nil, false, nil, nil, [:], nil)
        tailscaleSteps = nil
        // Keep the port bound until the previous publication has finished withdrawing.
        await previous?.value
        if asker != nil { await recoverPublication() }
        oldServer?.stop()
        guard let want else { return }
        guard let identity = load() else {
            following = Task {
                if await waitWhileActive(.seconds(15)) { hear(.settings) }
            }
            return
        }
        way = want
        refreshAgents()
        switch want {
        case .relay(let base):
            let relay = Relay(base: base, mac: identity.mac, secret: identity.secret)
            self.relay = relay
            following = Task { await follow(relay) }
        case .tailscale(let port), .address(_, let port): serve(port)
        }
    }

    /// Loads this Mac's id and secret at the relay, and the phones paired before. The first turn-on makes the id and
    /// secret. A Mac whose secret is gone (on another keychain, say) is a new Mac to the relay, because the relay knows
    /// an id by the secret that first came with it.
    private func load() -> (mac: String, secret: String)? {
        do {
            let kept = try store.daemonState(PhoneRecord.key, as: PhoneRecord.self)
            let existing = try Keychain.find("phone.mac")
            var next = kept ?? PhoneRecord(mac: PhoneSeal.random(16).base64URL)
            var restored: [String: PhoneDevice] = [:]
            for (id, phone) in next.devices {
                guard let text = try Keychain.find("phone.device.\(id)") else { continue }
                guard let key = Data(base64URL: text), key.count == 32 else {
                    throw RPCError.internalError("A paired phone's key is unreadable.")
                }
                guard let device = PhoneDevice(key: SymmetricKey(data: key), kept: phone) else {
                    throw RPCError.internalError("A paired phone's request number is unreadable.")
                }
                restored[id] = device
            }
            if kept == nil || existing == nil {
                if kept != nil { next.mac = PhoneSeal.random(16).base64URL }
                try store.setDaemonState(PhoneRecord.key, next)
            }
            let secret = existing ?? PhoneSeal.random(32).base64URL
            if existing == nil { try Keychain.set(secret, account: "phone.mac") }
            record = next
            devices = restored
            let takes = restored.values.contains { $0.push != nil }
            pushes.withLock { $0 = takes }
            return (next.mac, secret)
        } catch {
            record = nil
            devices = [:]
            pushes.withLock { $0 = false }
            failure = "Couldn't load this Mac's paired phones: \(error.rpcMessage)"
            return nil
        }
    }

    /// Publish one phone's new state only after its replay checkpoint and settings are durable.
    func save(_ phone: PhoneDevice?, id: String) throws {
        guard var next = record else { throw RPCError.internalError("The phone bridge is not ready.") }
        next.devices[id] = phone?.kept
        try store.setDaemonState(PhoneRecord.key, next)
        record = next
        devices[id] = phone
        devices[id]?.wasSaved()
        let takes = devices.values.contains { $0.push != nil }
        pushes.withLock { $0 = takes }
    }

    func forget(_ id: String) throws {
        guard let record else { throw RPCError.internalError("The phone bridge is not ready.") }
        guard record.devices[id] != nil else { return }
        try save(nil, id: id)
        cut(streams.filter { $0.value.device == id }.keys)
        Keychain.delete("phone.device.\(id)")
    }
}

// MARK: - Settings › Phone

extension PhoneBridge {
    func state() -> PhoneState {
        if let until = pairing?.until, until < Date() { pairing = nil }
        return PhoneState(
            relay: relay?.base.absoluteString, connected: connected, error: failure ?? cleanupError,
            link: pairing?.link,
            linkUntil: pairing?.until, via: way?.name, address: address, tailscale: tailscaleSteps,
            phones: (record?.devices ?? [:]).map {
                PairedPhone(id: $0.key, name: $0.value.name, push: devices[$0.key]?.push != nil)
            }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) })
    }

    /// Makes a pairing link that carries a key for one phone, good for ten minutes. The phone that seals its "pair"
    /// call with that key keeps the key.
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
            case .address(let address, _): connected ? address : nil
            case nil: nil
            }
        return found?.trimmingCharacters(in: ["/"])
    }

    func unpair(_ device: String) throws -> PhoneState {
        try forget(device)
        return state()
    }
}

// MARK: - Agents

extension PhoneBridge {
    /// Calls a daemon method as the user and decodes its result.
    func call<Method: RPCMethod>(_ method: Method) async throws -> Method.Result {
        guard let asker else { throw RPCError.internalError("The Mac is not answering.") }
        let result = try await asker(Method.name, try method.params() ?? .null)
        return try JSONDecoder().decode(Method.Result.self, from: result)
    }

    static var macName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }

    /// Bring all streams up to the snapshot's revision before returning its rows.
    func refreshAgents() {
        guard let rows = Log.session.attempt("reading the sessions", { try store.sessions() }) else { return }
        let present = Set(rows.map(\.id))
        for id in shown.keys where !present.contains(id) { removedAgent(id) }
        for row in rows { tell(live[row.id]?.snapshot ?? row) }
    }

    private func removedAgent(_ id: String) {
        if shown.removeValue(forKey: id) != nil { say("removed", .object(["id": .string(id)])) }
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
            workspace: worktree?.displayName ?? "",
            questionID: session.asksPermission
                ? live[session.id].flatMap { permissions.questionID($0, for: session.summary) } : nil)
    }

    /// Handles a saved change to a session. The phones hear of an agent that looks different now, or that is gone.
    private func tell(_ session: Session) {
        guard way != nil else { return }
        guard PhoneAgent.shown(session) else {
            removedAgent(session.id)
            return
        }
        let agent = agent(session)
        guard shown[session.id] != agent else { return }
        shown[session.id] = agent
        say("agent", .object(agent))
    }
}
