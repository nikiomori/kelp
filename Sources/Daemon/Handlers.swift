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
    /// The session it types into or stops: a program running inside one session may act on that one and on those it
    /// started (`parent`, `startedBy`, and theirs), no other. From outside every session, on any.
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
extension Clients: DaemonService { static func of(_ daemon: Daemon) -> Clients { daemon.clients } }
extension LSPHost: DaemonService { static func of(_ daemon: Daemon) -> LSPHost { daemon.lsp } }
extension SettingsEvents: DaemonService { static func of(_ daemon: Daemon) -> SettingsEvents { daemon.settingsEvents } }
extension UIStore: DaemonService {
    static func of(_ daemon: Daemon) -> UIStore { UIStore(store: daemon.store, clients: daemon.clients) }
}
extension ForgeWork: DaemonService {
    static func of(_ daemon: Daemon) -> ForgeWork { ForgeWork(forges: daemon.forges, workspaces: daemon.workspaces) }
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
}

extension Handled {
    static var inOrder: Bool { false }
    static var quick: Bool { false }
    func handle(_ service: Service) throws -> Result { throw RPCError.internalError("needs its connection") }
    func handle(_ service: Service, conn: Int) throws -> Result { try handle(service) }

    /// On the calling thread: an in-order method's, on the reader thread.
    static func answerNow(_ params: JSONValue, _ daemon: Daemon, conn: Int) throws -> Data {
        try Sessions.$asker.withValue(daemon.sessions.callers.caller(conn).origin) {
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
        try await Sessions.$asker.withValue(daemon.sessions.callers.caller(conn).origin) {
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

/// The methods the daemon answers, listed by domain beside their handlers; `Daemon.methods` is the one table of them.
enum Methods {}

extension Daemon {
    /// Whether the client on `conn` may make this call: the one place every path asks (`checked`, a session's input).
    /// A report comes from inside a session for that session only, by its process tree. A program an agent runs, or runs in
    /// a terminal it started (`parent`, `startedBy`, `origin`: all the daemon's, from the caller's process), reads, types
    /// into, stops and answers for only the sessions that agent started: any session a call names, in any of its fields,
    /// counts, so a method needn't remember to say so. A program the daemon started (an extension's, a git hook), one gone
    /// before it was looked at and one Kelp can't tell for the user's (`Caller.detached`) are held to the same with no
    /// session of their own; one under an agent the user typed into a terminal (`Caller.typedAgent`) as that terminal's
    /// agent. The user's own terminals, and programs under an app, drive any. Limit (docs/architecture.md): a program that
    /// has an app start one for the user to watch (`open -a Terminal`), and files left for the user to run.
    /// `caller`: who sent it, when that was found before (input queued for a session that wakes).
    func allow(_ method: any Answered, conn: Int, caller known: Caller? = nil) throws {
        if let refusal = method.onlyFromKelp { try clients.requireApp(conn, refusal) }
        let caller = known ?? sessions.callers.caller(conn)
        switch caller {
        case .user: return
        case .session(let own):
            if let id = method.reportsFor, own != id { throw RPCError.refused("A session speaks only for itself.") }
            guard try sessions.store.forAnAgent(own) else { return }
            try allowAgent(method, own: own)
        case .typedAgent(let own):
            if let id = method.reportsFor, own != id { throw RPCError.refused("A session speaks only for itself.") }
            try allowAgent(method, own: own, typed: true)
        case .unknown:
            // Looked up as it connects, a hook waiting for its answer is always found: one gone by then handed its
            // connection on, which is how a program would speak for a session not its own.
            try allowAgent(
                method, own: Callers.unknown,
                or: "Kelp couldn't tell which program sent this (it ended as it connected), so it may not do that.")
        case .kelpd:
            try allowAgent(
                method, own: Callers.ownProgram,
                or:
                    "A program Kelp runs (an extension's command or event, a repo's git hook) may not do that: it has no session to act for."
            )
        case .detached:
            try allowAgent(
                method, own: Callers.detached,
                or: "Kelp can't tell this program is yours (it runs outside every terminal and app: in the background, "
                    + "a launchd job, a tmux pane out of sight), so it's held to an agent's rules: run it from a terminal of yours."
            )
        }
    }

    /// One with no session of its own (`Caller.kelpd` and the like): no report, and an agent's rules. Refused in `why`'s
    /// words, then the rule's own (`SessionCreate`'s tmux…); anything else (the store) as it is.
    private func allowAgent(_ method: any Answered, own: String, or why: String) throws {
        if method.reportsFor != nil { throw RPCError.refused(why) }
        do { try allowAgent(method, own: own) } catch let error as RPCError where error.isRefusal {
            throw RPCError.refused(why + " " + error.message)
        }
    }

    /// What a program of an agent's (or of the daemon's, `own` = `Callers.ownProgram`) may not do.
    /// `typed`: an agent the user typed into `own`, a terminal of theirs: what it reaches is what it started there
    /// (`typed:` on its line), not everything the user started from that terminal.
    private func allowAgent(_ method: any Answered, own: String, typed: Bool = false) throws {
        if method.signs, method.reportsFor == nil {
            throw RPCError.refused(
                "What an agent writes for others says it's an agent's: run it from the agent's terminal, which names its session."
            )
        }
        func reaches(_ id: String) throws -> Bool {
            try sessions.store.lineage(id).contains {
                typed ? Caller.started($0.origin, byAgentTypedInto: own) : $0.id == own
            }
        }
        if let refusal = method.notForAgents { throw RPCError.refused(refusal) }
        if method.answersQuestion {
            throw RPCError.refused(
                "An agent's question is the user's to answer: in Kelp's window, or `kelp agents` in a terminal of theirs."
            )
        }
        let name = type(of: method).name
        guard AgentRules.methods.contains(name) else {
            throw RPCError.refused(
                "“\(name)” is the user's: an agent's program may call only what agents use (AgentRules.methods).")
        }
        if let id = method.typesInto, sessions.existing(id)?.asksSomething == true {
            throw RPCError.refused(
                "That session asks a question, the user's to answer; send again once it's answered, or tell the user "
                    + "what you'd answer.")
        }
        // The user's accounts (`accounts.*`) are theirs to pick: what an agent starts runs under its own.
        if let launch = method as? any LaunchOptions, let profile = launch.profile,
            try profile != sessions.store.session(own)?.profile
        {
            throw RPCError.refused(
                "An agent starts sessions under its own account, not another of the user's: leave out `profile`, or "
                    + "ask the user to start it from Kelp's window.")
        }
        // A typed agent's own session is the user's terminal it was typed into: it names it as anyone in it would (a child's
        // parent, its reports, its tab), but neither types into it nor acts on it (Stop, Restart, a question there).
        func itsOwn(_ id: String) -> Bool { id == own && !(typed && (id == method.typesInto || id == method.actsOn)) }
        for id in Set([method.actsOn, method.shows].compactMap { $0 } + (try sessions.store.named(by: method)))
        where !itsOwn(id) {
            guard try reaches(id) else {
                throw RPCError.refused(
                    "An agent acts only on its own session and the sessions it started: start one with `kelp session "
                        + "new`, or ask the user to do this one.")
            }
        }
        // Every workspace a call that acts names, whatever the field: not each method remembering to say. `inWorkspace` is
        // for what the walk can't see (the workspace on screen, `""`) and for a read held to the agent's own (a fetch).
        let workspaces = Set(
            [method.inWorkspace].compactMap { $0 }
                + (AgentRules.reads.contains(name) ? [] : try sessions.store.workspaces(namedBy: method)))
        for workspace in workspaces where try !sessions.store.works(own, in: workspace, typed: typed) {
            throw RPCError.refused(
                "An agent works only in its own workspace: make one with `kelp worktree create <branch>`, or ask the "
                    + "user to do this there.")
        }
        if let repo = method.makesInProject,
            try !sessions.store.worktrees(repo: repo).contains(where: {
                try sessions.store.works(own, in: $0.id, typed: typed)
            })
        {
            throw RPCError.refused("An agent makes workspaces only in the project it works in.")
        }
        if let ending = method.ends,
            try sessions.store.ending(ending).contains(where: { session in
                try (typed || session != own) && !reaches(session)
            })
        {
            throw RPCError.refused("An agent ends only its own sessions and the ones it started.")
        }
    }

    /// Every method the daemon answers, by name: one list, so none is answered twice (a second entry traps at launch).
    static let methods: [String: any Answered.Type] = {
        let sync: [any Handled.Type] =
            Methods.miscMethods + Methods.gitMethods + Methods.workspaceMethods + Methods.sessionMethods
            + Methods.integrationMethods + Methods.projectMethods
            + Methods.launchMethods + Methods.uiMethods + Methods.lspMethods + Methods.extensionMethods
            + Methods.vmMethods + Methods.databaseMethods + Methods.artifactMethods
        let async =
            Methods.asyncMethods + Methods.lspAsyncMethods + Methods.uiAsyncMethods + Methods.databaseAsyncMethods
        let all = sync.map { $0 as any Answered.Type } + async.map { $0 as any Answered.Type }
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
        case let error as GitHubError: RPCError.internalError(error.description)
        case let error as IntegrationError: RPCError.internalError(error.description)
        default: error
        }
    }

    /// gh / glab run in the folder here; a remote project's is only a marker under ~/.kelp, and their git would walk up to
    /// whatever repository holds it (a dotfiles home). Until they run on the host, they don't run at all: a `LocalForge`
    /// method is refused for one, or answers null when the sidebar asked by itself.
    private func refuseRemoteForge(_ methodType: any Answered.Type, _ params: JSONValue) throws -> Data? {
        guard let forge = methodType as? any LocalForge.Type,
            (try? store.repoPath(params)).map({ remotes.of($0.1) != nil }) == true
        else { return nil }
        if forge.quietOnRemote { return Data("null".utf8) }
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
