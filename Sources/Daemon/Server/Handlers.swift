import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations
import os

extension JSONValue {
    func req(_ key: String) throws -> String {
        guard let value = self[key]?.string else { throw RPCError.invalidParams("missing \(key)") }
        return value
    }
}

/// A method declared in Core (`RPCMethod`) that the daemon answers, sync (`Handled`) or async (`AsyncHandled`), listed
/// once in `Daemon.methods`. Its result is encoded straight into the reply (`answer`), never through a JSONValue.
protocol Answered: RPCMethod {
    /// Applied on the connection's reader thread, after what was sent before it, call or notification: only right in the
    /// order sent, and quick (`Handled` only). Everything else runs on a task of its own, its reply whenever it's ready.
    static var inOrder: Bool { get }
    /// The result as the reply's JSON.
    static func answer(_ params: JSONValue, _ daemon: Daemon, conn: Int) async throws -> Data
    /// Who may call it: nil for any client of the socket (the app, the CLI, agents and their scripts), else what anyone
    /// but Kelp's window is told (`Clients.requireApp`). Its params may decide (`state.set` of an `lsp.` key).
    var onlyFromKelp: String? { get }
    /// The session whose status it reports (hooks, `kelp report`, herdr's): a program running inside one session may
    /// report only for that one. From outside every session (the app, a terminal elsewhere), for any.
    var reportsFor: String? { get }
    /// The session it types into or stops. Not a gate of its own: every session a call names, in any field, is held to
    /// the agent's own and those it started (`Store.named(by:)`), so for one that exists this adds nothing. It does
    /// refuse an id that names no session, and keeps a typed agent from acting on the user's terminal it was typed into,
    /// which it may still name (`AgentRules.allow`).
    var actsOn: String? { get }
    /// Whether it answers an agent's question (Allow / Deny): the user's to answer, so never from a session an agent runs or
    /// started, which would approve its own question or another agent's.
    var answersQuestion: Bool { get }
    /// The workspace it works in (`kelp browser`'s tabs, a port's process): an agent works only in its own, whose
    /// pages may carry the user's login it was let into.
    var inWorkspace: String? { get }
    /// The sessions it ends with what it removes (a workspace, a project's): an agent ends only its own and those it
    /// started, never the user's other agents.
    var ends: Ending? { get }
    /// Why an agent, or a program it runs, may not call it at all (a routine starts agents of the user's later): nil if it may.
    var notForAgents: String? { get }
    /// The session it types keys into as they are: never an agent's while that one asks a question, which a key answers.
    var typesInto: String? { get }
    /// A session it shows (a tab of it), checked as any session a call names: a typed agent's own terminal included.
    var shows: String? { get }
    /// Words it leaves for another to read (a review comment), whose author is `reportsFor`'s: an agent names its session,
    /// or they would read as the user's.
    var signs: Bool { get }
    /// The project it makes something in (a workspace): one the agent works in, not any of the user's.
    var makesInProject: String? { get }
}

enum Ending { case workspace(String), project(String) }

extension Answered {
    var onlyFromKelp: String? { nil }
    var reportsFor: String? { nil }
    var actsOn: String? { nil }
    var answersQuestion: Bool { false }
    var inWorkspace: String? { nil }
    var ends: Ending? { nil }
    var notForAgents: String? { nil }
    var typesInto: String? { nil }
    var shows: String? { nil }
    var signs: Bool { false }
    var makesInProject: String? { nil }

    /// The method's params as its type, from a client allowed to call it: checked here, for every method.
    static func checked(_ params: JSONValue, _ daemon: Daemon, conn: Int) throws -> Self {
        let method = try decoded(params)
        try daemon.allow(method, conn: conn)
        return method
    }
}

/// What a method's handler is given (`Handled.Service`): one of the daemon's services, never the daemon itself, so it
/// reaches only what that service holds. A handler names the type it takes (`handle(_ sessions: Sessions)`); which of
/// the daemon's that is, each service says once, here.
protocol DaemonService { static func of(_ daemon: Daemon) -> Self }

/// For a method that needs nothing of the daemon's.
struct NoService: DaemonService { static func of(_ daemon: Daemon) -> NoService { NoService() } }

extension FileService: DaemonService { static func of(_ daemon: Daemon) -> FileService { daemon.files } }
extension Watches: DaemonService { static func of(_ daemon: Daemon) -> Watches { daemon.watches } }
extension AgentUsage: DaemonService { static func of(_ daemon: Daemon) -> AgentUsage { daemon.agentUsage } }
extension SettingsStore: DaemonService { static func of(_ daemon: Daemon) -> SettingsStore { daemon.settings } }
extension Remotes: DaemonService { static func of(_ daemon: Daemon) -> Remotes { daemon.remotes } }
extension Sessions: DaemonService { static func of(_ daemon: Daemon) -> Sessions { daemon.sessions } }
extension AgentAddons: DaemonService {
    static func of(_ daemon: Daemon) -> AgentAddons { AgentAddons(sessions: daemon.sessions) }
}
extension SessionSetup: DaemonService { static func of(_ daemon: Daemon) -> SessionSetup { daemon.sessions.setup } }
extension SessionProcesses: DaemonService {
    static func of(_ daemon: Daemon) -> SessionProcesses { daemon.sessions.processes }
}
extension Turns: DaemonService { static func of(_ daemon: Daemon) -> Turns { daemon.sessions.turns } }
extension PermissionWaits: DaemonService {
    static func of(_ daemon: Daemon) -> PermissionWaits { daemon.sessions.permissions }
}
extension Workspaces: DaemonService { static func of(_ daemon: Daemon) -> Workspaces { daemon.workspaces } }
extension SourceControl: DaemonService {
    static func of(_ daemon: Daemon) -> SourceControl { daemon.sourceControl }
}
extension Forges: DaemonService { static func of(_ daemon: Daemon) -> Forges { daemon.forges } }
extension Databases: DaemonService { static func of(_ daemon: Daemon) -> Databases { daemon.workspaces.databases } }
extension VMService: DaemonService { static func of(_ daemon: Daemon) -> VMService { daemon.vms } }
extension PhoneBridge: DaemonService {
    static func of(_ daemon: Daemon) -> PhoneBridge { daemon.sessions.phone }
}
extension Clients: DaemonService { static func of(_ daemon: Daemon) -> Clients { daemon.clients } }
extension LSPHost: DaemonService { static func of(_ daemon: Daemon) -> LSPHost { daemon.lsp } }
extension SettingsEvents: DaemonService { static func of(_ daemon: Daemon) -> SettingsEvents { daemon.settingsEvents } }
extension UIStore: DaemonService {
    static func of(_ daemon: Daemon) -> UIStore { UIStore(store: daemon.store, clients: daemon.clients) }
}
extension ForgeWork: DaemonService {
    static func of(_ daemon: Daemon) -> ForgeWork { ForgeWork(forges: daemon.forges, workspaces: daemon.workspaces) }
}
extension Shutdown: DaemonService {
    static func of(_ daemon: Daemon) -> Shutdown {
        Shutdown { [weak daemon] in
            daemon?.drainReplies()
            daemon?.stop()
            exit(0)
        }
    }
}
extension Upgrade: DaemonService {
    static func of(_ daemon: Daemon) -> Upgrade {
        let root = daemon.root, offloads = daemon.offloads
        return Upgrade(
            executable: Daemon.executable, root: root, adoptable: { Handover.adoptable(Daemon.executable, home: root) },
            waitIdle: { offloads.waitIdle(seconds: 5) }
        ) { [weak daemon] in daemon?.upgrade(checked: true) }
    }
}

/// Answered on a thread of its own (`offload`): git, files, the store. `handle(_:conn:)` for the few that need the asking
/// connection (attach, detach, ui.publish); the rest write `handle(_:)`.
protocol Handled: Answered {
    associatedtype Service: DaemonService
    /// Memory or a short write to the store, never a program: answered on a thread of its own at once, not after a slot
    /// in `offload` behind slow git, gh or ssh (an agent's `kelp hook` waits for its reply). `Subprocess.quickOnly`
    /// holds it to that: one that starts a program fails instead of quietly becoming slow.
    static var quick: Bool { get }
    func handle(_ service: Service) throws -> Result
    func handle(_ service: Service, conn: Int) throws -> Result
    /// An in-order method that answers later, off the reader thread (`SessionInput`'s, from its session's lane): true when
    /// it took the call, `reply` then given its result. `allowed` is `Daemon.allow` for the caller it came from.
    static func answerLater(
        _ params: JSONValue, _ service: Service, allowed: @escaping @Sendable (any Answered) throws -> Void,
        reply: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) -> Bool
    /// Once an in-order method's reply is queued: what must wait until it's on its way out (daemon.upgrade's hand-over,
    /// daemon.shutdown's stop).
    static func replied(_ service: Service)
    /// A call that sends its reply itself, where a result returned can't go (`session.attach`'s, queued inside the
    /// session's lock): true when it did, false to be answered as any other. `checked`: the call, from a caller allowed
    /// to make it (`Answered.checked`).
    static func respond(
        _ checked: () throws -> Self, _ service: Service, conn: Int,
        reply: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) async -> Bool
}

extension Handled {
    static var inOrder: Bool { false }
    static var quick: Bool { false }
    func handle(_ service: Service) throws -> Result { throw RPCError.internalError("needs its connection") }
    func handle(_ service: Service, conn: Int) throws -> Result { try handle(service) }
    static func answerLater(
        _ params: JSONValue, _ service: Service, allowed: @escaping @Sendable (any Answered) throws -> Void,
        reply: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) -> Bool { false }
    static func replied(_ service: Service) {}
    static func respond(
        _ checked: () throws -> Self, _ service: Service, conn: Int,
        reply: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) async -> Bool { false }

    /// The three above with this method's service, for the daemon's dispatch (`Daemon.serve`).
    static func answerLater(
        _ params: JSONValue, in daemon: Daemon, conn: Int,
        reply: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) -> Bool {
        answerLater(params, Service.of(daemon), allowed: daemon.allowing(conn), reply: reply)
    }
    static func replied(in daemon: Daemon) { replied(Service.of(daemon)) }
    static func respond(
        _ params: JSONValue, in daemon: Daemon, conn: Int,
        reply: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) async -> Bool {
        await respond({ try checked(params, daemon, conn: conn) }, Service.of(daemon), conn: conn, reply: reply)
    }

    /// On the calling thread: an in-order method's, on the reader thread.
    static func answerNow(_ params: JSONValue, _ daemon: Daemon, conn: Int) throws -> Data {
        try Sessions.$asker.withValue(daemon.callers.caller(conn).origin) {
            try JSONEncoder().encode(checked(params, daemon, conn: conn).handle(Service.of(daemon), conn: conn))
        }
    }
    static func answer(_ params: JSONValue, _ daemon: Daemon, conn: Int) async throws -> Data {
        try await daemon.offload(quick: quick) { try answerNow(params, daemon, conn: conn) }
    }
}

/// A method that waits on a web API (Linear, Jira, Bitbucket): async, with its gh / git calls through `offload`.
/// `handle(_:conn:)` for one that reports progress to the asking connection (repo.clone).
protocol AsyncHandled: Answered {
    associatedtype Service: DaemonService
    func handle(_ service: Service) async throws -> Result
    func handle(_ service: Service, conn: Int) async throws -> Result
}

extension AsyncHandled {
    static var inOrder: Bool { false }
    func handle(_ service: Service) async throws -> Result { throw RPCError.internalError("needs its connection") }
    func handle(_ service: Service, conn: Int) async throws -> Result { try await handle(service) }

    static func answer(_ params: JSONValue, _ daemon: Daemon, conn: Int) async throws -> Data {
        try await Sessions.$asker.withValue(daemon.callers.caller(conn).origin) {
            try JSONEncoder().encode(await checked(params, daemon, conn: conn).handle(Service.of(daemon), conn: conn))
        }
    }
}

extension RPCMethod {
    /// The method's params as its type; a bad or missing field is the caller's error.
    static func decoded(_ params: JSONValue) throws -> Self {
        do { return try (params == .null ? .object([:]) : params).decode(Self.self) } catch DecodingError.keyNotFound(
            let key, _)
        {
            throw RPCError.invalidParams("missing \(key.stringValue)")
        } catch { throw RPCError.invalidParams("\(name): \(error)") }
    }
}

/// The methods the daemon answers: each handler file ends with the list of those it answers, and `Daemon.methods` is
/// the one table of them.
enum Methods {}

extension Daemon {
    /// Whether the client on `conn` may make this call: the one place every path asks (`checked`, a session's input). A
    /// call only Kelp's window makes (`onlyFromKelp`), then what its caller may reach (`AgentRules.allow`).
    /// `caller`: who sent it, when that was found before (input queued for a session that wakes).
    func allow(_ method: any Answered, conn: Int, caller known: Caller? = nil) throws {
        if let refusal = method.onlyFromKelp { try clients.requireApp(conn, refusal) }
        try AgentRules.allow(method, caller: known ?? callers.caller(conn), store: store, live: sessions.live)
    }

    /// `allow` for `conn`'s caller as it is now, asked again later as that caller: input queued for a session that wakes
    /// is asked from the lane, when its connection may be gone, and a gone one can't be told apart (`Callers.caller`).
    func allowing(_ conn: Int) -> @Sendable (any Answered) throws -> Void {
        let caller = callers.caller(conn)
        return { [self] in try allow($0, conn: conn, caller: caller) }
    }

    /// Every method the daemon answers, by name: one list, so none is answered twice (a second entry traps at launch).
    static let methods: [String: any Answered.Type] = {
        let all: [any Answered.Type] =
            [DaemonInfo.self] + Methods.addonMethods + Methods.commentMethods + Methods.commitPlanMethods
            + Methods.daemonMethods
            + Methods.databaseApplyMethods
            + Methods.databaseMethods + Methods.databaseHealthMethods + Methods.databaseImportMethods
            + Methods.databaseLibraryMethods + Methods.extensionMethods + Methods.fileMethods + Methods.gitMethods
            + Methods.hostStatsMethods + Methods.integrationMethods + Methods.lspMethods + Methods.launchMethods
            + Methods.cloneMethods + Methods.phoneMethods + Methods.portMethods + Methods.processMethods
            + Methods.recapMethods
            + Methods.remoteMethods + Methods.routineMethods + Methods.runMethods + Methods.scriptMethods
            + Methods.artifactMethods + Methods.sessionEditMethods + Methods.sessionMethods + Methods.hookMethods
            + Methods.skillMethods + Methods.settingsMethods + Methods.tmuxMethods + Methods.trackerMethods
            + Methods.transcriptMethods + Methods.turnMethods + Methods.uiMethods + Methods.usageMethods
            + Methods.vmConfigureMethods + Methods.vmMethods + Methods.watchMethods + Methods.workspaceMethods
        return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }()

    /// The reply's result, encoded once.
    func answer(_ method: String, _ params: JSONValue, conn: Int) async throws -> Data {
        guard let methodType = Self.methods[method] else { throw RPCError.methodNotFound }
        if let quiet = try refuseRemoteForge(methodType, params) { return quiet }
        do { return try await methodType.answer(params, self, conn: conn) } catch { throw Self.rpc(error) }
    }

    /// An in-order method, here on the connection's reader thread, where everything sent after it waits: it starts no
    /// program (`Subprocess.quickOnly` refuses one, so the call fails at once instead of holding up the connection), and
    /// one that still took long says so in the log.
    func answerNow(_ methodType: any Handled.Type, _ params: JSONValue, conn: Int) throws -> Data {
        if let quiet = try refuseRemoteForge(methodType, params) { return quiet }
        let start = DispatchTime.now()
        defer {
            let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if ms >= 100 {
                Log.rpc.error("in-order \(methodType.name, privacy: .public) held its connection for \(ms) ms")
            }
        }
        do { return try Subprocess.quickOnly { try methodType.answerNow(params, self, conn: conn) } } catch {
            throw Self.rpc(error)
        }
    }

    /// The same as a value, for callers that read it by hand (tests).
    func handle(_ method: String, _ params: JSONValue, conn: Int) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await answer(method, params, conn: conn))
    }

    /// git's and the integrations' own errors, as the app shows them; anything else as it is.
    private static func rpc(_ error: Error) -> Error {
        switch error {
        case let error as GitError: RPCError.internalError(error.message)
        case let error as ForgeError: RPCError.internalError(error.description)
        case let error as IntegrationError: RPCError.internalError(error.description)
        default: error
        }
    }

    /// gh / glab run in the folder here; a remote project's is only a marker under ~/.kelp, and their git would walk up to
    /// whatever repository holds it (a dotfiles home). Until they run on the host, they don't run at all: a `LocalForge`
    /// method is refused for one, or answers null when the sidebar asked by itself.
    private func refuseRemoteForge(_ methodType: any Answered.Type, _ params: JSONValue) throws -> Data? {
        guard Methods.localForge.contains(methodType.name),
            (try? store.repoPath(params)).map({ remotes.of($0.1) != nil }) == true
        else { return nil }
        if Methods.quietOnRemote.contains(methodType.name) { return Data("null".utf8) }
        throw RPCError.invalidParams("Pull requests and CI aren't available for remote projects yet.")
    }

    /// git, gh and ssh hold their thread until they exit, and Swift's cooperative pool has one thread per core: a few slow
    /// ones (the sidebar asks every folder's PR at once) would stall every other request, a terminal's attach included.
    /// A thread of its own, not GCD's pool: that one stops at 64 threads (concurrent queues Kelp makes draw from it too),
    /// Swift's tasks run on it as well, and once slow hosts hold them all no request is answered. git, gh and ssh all have
    /// time limits, so a thread is held only while its program runs; at most `offloadLimit` run at once, the rest wait
    /// their turn in the order they came, holding no thread meanwhile. `quick` work (`Handled.quick`) takes no slot and
    /// starts no program.
    func offload<T: Sendable>(quick: Bool = false, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await offloads.run(quick: quick, work)
    }

    /// The longest request line read from a client (256 MiB).
    static let lineLimit = 256 << 20
    /// Requests one client may have waiting for their answer at once (the app's sidebar asks a few hundred at most).
    static let pendingLimit = 4096

    /// 128 at once: wider than any fan-out Kelp makes itself (the sidebar's PR per folder, every watched folder's status),
    /// and than the slow ones that once stalled every request (aRequestIsAnsweredWhileManySlowOnesRun holds 80): the next
    /// request still runs while that many wait on hosts that don't answer. Past it, a runaway client queues instead of
    /// starting a program per request: each is a thread here, two more reading its pipes (`Subprocess`) and a process,
    /// and the user's processes are capped for the whole login (kern.maxprocperuid), terminals included.
    static let offloadLimit = 128
}

extension DaemonInfo: Handled {
    static var quick: Bool { true }
    func handle(_ sessions: Sessions) throws -> Result {
        Result(
            path: URL(fileURLWithPath: Daemon.executable).resolvingSymlinksInPath().path,
            binaryMTime: Daemon.binaryMTime, pid: Int(getpid()),
            liveSessions: sessions.live.all.filter { $0.snapshot.status != .exited }.count)
    }
}
