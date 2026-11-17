import AgentData
import Agents
import Core
import Foundation
import GitKit
import Integrations
import os

/// A method declared in Core (`RPCMethod`) that the daemon answers, sync (`Handled`) or async (`AsyncHandled`), listed
/// once in `Daemon.methods`. Its result is encoded straight into the reply (`answer`), never through a JSONValue.
protocol Answered: RPCMethod {
    /// True for a method applied on the connection's reader thread, after every call or notification sent before it.
    /// Only a quick method that is right only in the order sent is applied this way (`Handled` only). Every other
    /// method runs on a task of its own and replies whenever it's ready.
    static var inOrder: Bool { get }
    /// The result as the reply's JSON.
    static func answer(_ params: JSONValue, _ daemon: Daemon, conn: Int) async throws -> Data
    /// Who may call the method, and on what (`Fence`). It is checked before the method runs, for every caller
    /// (`Daemon.allow`).
    var fence: Fence { get }
    /// Whether an agent's program may call the method at all, and whether to read or to act (`AgentRules.methods`). It
    /// is `.none` by default.
    static var agents: AgentAccess { get }
    /// For a method that runs gh in the project's folder, what it answers for a remote project with no GitHub origin
    /// (`Daemon.refuseRemoteForge`). It is nil for a method that runs nothing there.
    static var onRemote: RemoteForge? { get }
}

enum Ending { case workspace(String), project(String) }

/// Who may call a method and what it reaches, as its handler says once (`Answered.fence`). `Clients.requireApp` and
/// `AgentRules.allow` check it before the method runs. Each gate is a label of the init and is off by default, so a
/// misspelled gate doesn't compile and no gate is left to a protocol's default.
struct Fence {
    /// Who may call the method. nil lets any client of the socket call it (the app, the CLI, agents and their scripts).
    /// Otherwise it is the refusal that anyone but Kelp's window is told (`Clients.requireApp`). The params may decide
    /// (`state.set` of an `lsp.` key).
    var onlyFromKelp: String?
    /// The session whose status the method reports (hooks, `kelp report`, herdr's). A program inside a session reports
    /// only for that session; from outside every session (the app, a terminal elsewhere), it may report for any.
    var reportsFor: String?
    /// The session the method types into or stops. It isn't a gate of its own, because every session a call names, in
    /// any field, is held to the agent's own and those it started (`Store.named(by:)`). So for a session that exists it
    /// adds nothing. It does refuse an id that names no session, and it keeps a typed agent from acting on the user's
    /// terminal it was typed into, which the agent may still name (`AgentRules.allow`).
    var actsOn: String?
    /// Whether the method answers an agent's question (Allow / Deny). Only the user may answer, so it is never accepted
    /// from a session an agent runs or started, which could approve its own question or another agent's.
    var answersQuestion: Bool = false
    /// The workspace the method works in (`kelp browser`'s tabs, a port's process). An agent works only in its own
    /// workspace, whose pages may carry the user's logins that the agent was let into.
    var inWorkspace: String?
    /// A folder the method writes in (an artifact's `cwd`). It is held to the workspace that holds the folder, as
    /// `inWorkspace` is. A folder outside every workspace (a chat with no project) is open to anyone.
    var writesInFolder: String?
    /// The sessions the method ends along with what it removes (a workspace, a project): an agent may end only its own
    /// sessions and those it started, never the user's other agents.
    var ends: Ending?
    /// Why an agent, or a program it runs, may not call the method at all (deleting a routine, which is the user's
    /// own). It is nil if it may.
    var notForAgents: String?
    /// The session the method types raw keys into. It is never an agent's session while that agent asks a question,
    /// because a key would answer it.
    var typesInto: String?
    /// A session the method shows (a tab of it). It is checked like any session a call names, a typed agent's own
    /// terminal included.
    var shows: String?
    /// Whether the method leaves words for another to read (a review comment), signed by the `reportsFor` session. An
    /// agent must name its session, or the words would read as the user's.
    var signs: Bool = false
    /// The project the method makes something in (a workspace). It must be a project the agent works in, not any of the
    /// user's.
    var makesInProject: String?
}

extension Answered {
    var fence: Fence { Fence() }
    static var agents: AgentAccess { .none }
    static var onRemote: RemoteForge? { nil }

    /// Decodes the params as the method's type and checks that the client may call it. Every method is checked here.
    static func checked(_ params: JSONValue, _ daemon: Daemon, conn: Int) throws -> Self {
        let method = try decoded(params)
        try daemon.allow(method, conn: conn)
        return method
    }
}

/// What a method's handler is given (`Handled.Service`): one of the daemon's services, never the daemon itself, so the
/// handler reaches only what that service holds. A handler names the type it takes (`handle(_ sessions: Sessions)`),
/// and each service says once, here, which part of the daemon it is.
protocol DaemonService { static func of(_ daemon: Daemon) -> Self }

/// For a method that needs nothing of the daemon's.
struct NoService: DaemonService { static func of(_ daemon: Daemon) -> NoService { NoService() } }

extension FileService: DaemonService { static func of(_ daemon: Daemon) -> FileService { daemon.files } }
extension Watches: DaemonService { static func of(_ daemon: Daemon) -> Watches { daemon.watches } }
extension AgentUsage: DaemonService { static func of(_ daemon: Daemon) -> AgentUsage { daemon.agentUsage } }
extension SettingsStore: DaemonService { static func of(_ daemon: Daemon) -> SettingsStore { daemon.settings } }
extension Remotes: DaemonService { static func of(_ daemon: Daemon) -> Remotes { daemon.remotes } }
extension Sessions: DaemonService { static func of(_ daemon: Daemon) -> Sessions { daemon.sessions } }
extension ChatMoves: DaemonService {
    static func of(_ daemon: Daemon) -> ChatMoves { .init(workspaces: daemon.workspaces, sessions: daemon.sessions) }
}
extension AgentAddons: DaemonService {
    static func of(_ daemon: Daemon) -> AgentAddons { .init(setup: daemon.sessions.setup, live: daemon.sessions.live) }
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
extension Routines: DaemonService { static func of(_ daemon: Daemon) -> Routines { daemon.workspaces.routines } }
extension CommitPlans: DaemonService {
    static func of(_ daemon: Daemon) -> CommitPlans { daemon.workspaces.commitPlans }
}
extension Store: DaemonService { static func of(_ daemon: Daemon) -> Store { daemon.store } }
extension DiskUsage: DaemonService {
    static func of(_ daemon: Daemon) -> DiskUsage { DiskUsage(workspaces: daemon.workspaces) }
}
extension SourceControl: DaemonService {
    static func of(_ daemon: Daemon) -> SourceControl { daemon.sourceControl }
}
extension Forges: DaemonService { static func of(_ daemon: Daemon) -> Forges { daemon.forges } }
extension Databases: DaemonService { static func of(_ daemon: Daemon) -> Databases { daemon.workspaces.databases } }
extension VMService: DaemonService { static func of(_ daemon: Daemon) -> VMService { daemon.vms } }
extension VMAsking: DaemonService {
    static func of(_ daemon: Daemon) -> VMAsking {
        VMAsking(vms: daemon.vms, asks: daemon.sessions.asks, offloads: daemon.offloads)
    }
}
extension PhoneBridge: DaemonService {
    static func of(_ daemon: Daemon) -> PhoneBridge { daemon.sessions.phone }
}
extension Clients: DaemonService { static func of(_ daemon: Daemon) -> Clients { daemon.clients } }
extension LSPHost: DaemonService { static func of(_ daemon: Daemon) -> LSPHost { daemon.lsp } }
extension SettingsEvents: DaemonService { static func of(_ daemon: Daemon) -> SettingsEvents { daemon.settingsEvents } }
extension UIStore: DaemonService {
    static func of(_ daemon: Daemon) -> UIStore { UIStore(store: daemon.store, clients: daemon.clients) }
}
extension BrowserRelay: DaemonService {
    static func of(_ daemon: Daemon) -> BrowserRelay { BrowserRelay(ui: .of(daemon), asks: daemon.sessions.asks) }
}
extension ForgeWork: DaemonService {
    static func of(_ daemon: Daemon) -> ForgeWork {
        ForgeWork(forges: daemon.forges, workspaces: daemon.workspaces, offloads: daemon.offloads)
    }
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
        let root = daemon.root, offloads = daemon.offloads, store = daemon.store
        return Upgrade(
            executable: Daemon.executable, root: root,
            adoptable: { Handover.adoptable(Daemon.executable, home: root, store: store.copy) },
            waitIdle: { offloads.waitIdle(seconds: 5) }
        ) { [weak daemon] in daemon?.upgrade(checked: true) }
    }
}

/// A method answered on a thread of its own (`offload`), for git, files and the store. The few that need the connection
/// that asked (attach, detach, ui.publish) write `handle(_:conn:)`; the rest write `handle(_:)`.
protocol Handled: Answered {
    associatedtype Service: DaemonService
    /// True for a method that only reads memory or makes a short write to the store, and never runs a program. It is
    /// answered on a thread of its own at once, not after a slot in `offload` behind slow git, gh or ssh (an agent's
    /// `kelp hook` waits for its reply). `Subprocess.quickOnly` enforces that, so a quick method that starts a program
    /// fails instead of quietly becoming slow.
    static var quick: Bool { get }
    func handle(_ service: Service) throws -> Result
    func handle(_ service: Service, conn: Int) throws -> Result
    /// For an in-order method that answers later, off the reader thread (`SessionInput`, from its session's lane).
    /// Returns true when it took the call, and then `reply` gets the result. `allowed` is `Daemon.allow` for the caller
    /// the call came from.
    static func answerLater(
        _ params: JSONValue, _ service: Service, allowed: @escaping @Sendable (any Answered) throws -> Void,
        reply: @escaping @Sendable (Swift.Result<Data, Error>) -> Void
    ) -> Bool
    /// Runs what has to wait until an in-order method's reply has left (the hand-over of daemon.upgrade, the stop of
    /// daemon.shutdown).
    static func replied(_ service: Service)
    /// For a call that sends its reply itself, where a returned result can't go (`session.attach`, whose reply is
    /// queued inside the session's lock). Returns true when it replied, or false to be answered like any other call.
    /// `checked` returns the call, from a caller allowed to make it (`Answered.checked`).
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

    /// The three functions above, called with this method's service, for the daemon's dispatch (`Daemon.serve`).
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

    /// Answers on the calling thread, which for an in-order method is the reader thread.
    static func answerNow(_ params: JSONValue, _ daemon: Daemon, conn: Int) throws -> Data {
        try Sessions.$asker.withValue(daemon.callers.caller(conn).origin) {
            try JSONEncoder().encode(checked(params, daemon, conn: conn).handle(Service.of(daemon), conn: conn))
        }
    }
    static func answer(_ params: JSONValue, _ daemon: Daemon, conn: Int) async throws -> Data {
        try await daemon.offload(quick: quick) { try answerNow(params, daemon, conn: conn) }
    }
}

/// A method that waits on a web API (Linear, Jira, Bitbucket). It is async, and its gh / git calls go through
/// `offload`. A method that reports progress to the asking connection (repo.clone) writes `handle(_:conn:)`.
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
    /// Throws unless the client on `conn` may make this call. This is the one place every path asks (`checked`, a
    /// session's input). It checks calls that only Kelp's window makes (`onlyFromKelp`) first, then what the caller may
    /// reach (`AgentRules.allow`).
    /// `caller` is who sent the call, when that was found earlier (input queued for a session that wakes).
    func allow(_ method: any Answered, conn: Int, caller known: Caller? = nil) throws {
        if let refusal = method.fence.onlyFromKelp { try clients.requireApp(conn, refusal) }
        try AgentRules.allow(
            method, caller: known ?? callers.caller(conn), store: store, live: sessions.live,
            databases: workspaces.databases)
    }

    /// Returns `allow` for the caller on `conn` as it is now, to be asked later as that same caller. Input queued for a
    /// session that wakes is checked from the lane, when its connection may be gone, and a gone connection can't be
    /// told apart (`Callers.caller`).
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

    /// Answers `method` and returns the reply's result, encoded once.
    func answer(_ method: String, _ params: JSONValue, conn: Int) async throws -> Data {
        guard let methodType = Self.methods[method] else { throw RPCError.methodNotFound }
        if let quiet = try await refuseRemoteForge(methodType, params) { return quiet }
        do { return try await methodType.answer(params, self, conn: conn) } catch { throw Self.rpc(error) }
    }

    /// Answers an in-order method here on the connection's reader thread, where everything sent after it waits. It may
    /// start no program (`Subprocess.quickOnly` refuses one, so the call fails at once instead of holding up the
    /// connection), and a method that still took long says so in the log. No in-order method runs gh (`onRemote`,
    /// `refuseRemoteForge`).
    func answerNow(_ methodType: any Handled.Type, _ params: JSONValue, conn: Int) throws -> Data {
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

    /// The same answer decoded as a value, for callers that read it by hand (tests).
    func handle(_ method: String, _ params: JSONValue, conn: Int) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await answer(method, params, conn: conn))
    }

    /// Turns errors from git and the integrations into ones the app shows. Any other error passes through as it is.
    static func rpc(_ error: Error) -> Error {
        switch error {
        case let error as GitError: RPCError.internalError(error.message)
        case let error as ForgeError: RPCError.internalError(error.description)
        case let error as IntegrationError: RPCError.internalError(error.description)
        default: error
        }
    }

    /// gh / glab run in the project's folder here. A remote project's folder is only a marker under ~/.kelp, and their
    /// git would walk up to whatever repository holds it (a dotfiles home). For a remote project on GitHub, gh runs on
    /// the repository its origin names (`HostRepo`). On GitLab or elsewhere, a method that runs gh (`onRemote`) is
    /// refused, or answers null when the sidebar asked.
    /// That origin is read on the host over ssh, through `offload` like any git run, and only for a remote project's
    /// call. When it was read on the request's own task, a host that didn't answer held a pool thread for each of the
    /// sidebar's reads.
    private func refuseRemoteForge(_ methodType: any Answered.Type, _ params: JSONValue) async throws -> Data? {
        guard let onRemote = methodType.onRemote, let path = (try? store.repoPath(params)).map({ $0.1 }),
            remotes.of(path) != nil, try await offloads.run({ GitHub.repo(onHost: path) }) == nil
        else { return nil }
        if onRemote == .quiet { return Data("null".utf8) }
        throw RPCError.invalidParams("Pull requests and CI aren't available for remote projects yet.")
    }

    /// Runs `work` on a thread of its own. git, gh and ssh hold their thread until they exit, and Swift's cooperative
    /// pool has one thread per core, so a few slow ones (the sidebar asks every folder's PR at once) would stall every
    /// other request, a terminal's attach included. It doesn't use GCD's pool either: that pool stops at 64 threads
    /// (concurrent queues Kelp makes draw from it too), Swift's tasks run on it as well, and once slow hosts hold them
    /// all no request is answered. git, gh and ssh all have time limits, so a thread is held only while its program
    /// runs. At most `offloadLimit` run at once, and the rest wait their turn in the order they came, holding no thread
    /// meanwhile. `quick` work (`Handled.quick`) takes no slot and starts no program.
    func offload<T: Sendable>(quick: Bool = false, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await offloads.run(quick: quick, work)
    }

    /// The longest request line read from a client (256 MiB).
    static let lineLimit = 256 << 20
    /// Requests one client may have waiting for their answer at once (the app's sidebar asks a few hundred at most).
    static let pendingLimit = 4096

    /// Up to 128 requests run at once. That is wider than any fan-out Kelp makes itself (the sidebar asks for a PR per
    /// folder, and every watched folder's status), and wider than the slow requests that once stalled every other one
    /// (the test aRequestIsAnsweredWhileManySlowOnesRun holds 80), so the next request still runs while that many wait
    /// on hosts that don't answer. Past the limit, a runaway client's requests queue instead of each starting a
    /// program, because every request is a thread here, plus two threads reading its pipes (`Subprocess`) and a
    /// process. The user's processes are capped for the whole login (kern.maxprocperuid), terminals included.
    static let offloadLimit = 128
}

extension AgentRules {
    /// The methods that an agent's program, or a program kelpd runs (an extension's, a git hook), may call, from each
    /// handler's `agents`.
    static let methods: Set<String> = Set(Daemon.methods.filter { $0.value.agents != .none }.keys)
    /// The methods that only read (`AgentAccess.reads`).
    static let reads: Set<String> = Set(Daemon.methods.filter { $0.value.agents == .reads }.keys)
}

extension DaemonInfo: Handled {
    static let agents = AgentAccess.reads
    static var quick: Bool { true }
    func handle(_ sessions: Sessions) throws -> Result {
        Result(
            path: URL(fileURLWithPath: Daemon.executable).resolvingSymlinksInPath().path,
            binaryMTime: Daemon.binaryMTime, pid: Int(getpid()),
            liveSessions: sessions.live.all.filter { $0.snapshot.status != .exited }.count)
    }
}
