import Foundation
import ServiceManagement
import os
import Core
import GitKit
import Agents
import AgentData
import Integrations

extension JSONValue {
    func req(_ k: String) throws -> String {
        guard let s = self[k]?.string else { throw RPCError.invalidParams("missing \(k)") }
        return s
    }
}

/// A method declared in Core (`RPCMethod`) that the daemon answers, sync (`Handled`) or async (`AsyncHandled`), listed
/// once in `Daemon.methods`. Its result is encoded straight into the reply (`answer`), never through a JSONValue.
protocol Answered: RPCMethod {
    /// Applied on the connection's reader thread, after what was sent before it, call or notification: only right in the
    /// order sent, and quick (`Handled` only). Everything else runs on a task of its own, its reply whenever it's ready.
    static var inOrder: Bool { get }
    /// The result as the reply's JSON.
    static func answer(_ p: JSONValue, _ d: Daemon, conn: Int) async throws -> Data
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

    /// The method's params as its type, from a client allowed to call it: checked here, for every method.
    static func checked(_ p: JSONValue, _ d: Daemon, conn: Int) throws -> Self {
        let m = try decoded(p)
        try d.allow(m, conn: conn)
        return m
    }
}

/// What a method's handler is given (`Handled.Service`): one of the daemon's services, never the daemon itself, so it
/// reaches only what that service holds. A handler names the type it takes (`handle(_ sessions: Sessions)`); which of
/// the daemon's that is, each service says once, here.
protocol DaemonService { static func of(_ d: Daemon) -> Self }

/// For a method that needs nothing of the daemon's.
struct NoService: DaemonService { static func of(_ d: Daemon) -> NoService { NoService() } }

extension FileService: DaemonService { static func of(_ d: Daemon) -> FileService { d.files } }
extension Watches: DaemonService { static func of(_ d: Daemon) -> Watches { d.watches } }
extension AgentUsage: DaemonService { static func of(_ d: Daemon) -> AgentUsage { d.agentUsage } }
extension SettingsStore: DaemonService { static func of(_ d: Daemon) -> SettingsStore { d.settings } }
extension Remotes: DaemonService { static func of(_ d: Daemon) -> Remotes { d.remotes } }
extension Sessions: DaemonService { static func of(_ d: Daemon) -> Sessions { d.sessions } }
extension Workspaces: DaemonService { static func of(_ d: Daemon) -> Workspaces { d.workspaces } }
extension Forges: DaemonService { static func of(_ d: Daemon) -> Forges { d.forges } }
extension VMService: DaemonService { static func of(_ d: Daemon) -> VMService { d.vms } }
extension Clients: DaemonService { static func of(_ d: Daemon) -> Clients { d.clients } }
extension LSPHost: DaemonService { static func of(_ d: Daemon) -> LSPHost { d.lsp } }
extension SettingsEvents: DaemonService { static func of(_ d: Daemon) -> SettingsEvents { d.settingsEvents } }
extension UIStore: DaemonService { static func of(_ d: Daemon) -> UIStore { UIStore(store: d.store, clients: d.clients) } }
extension ForgeWork: DaemonService { static func of(_ d: Daemon) -> ForgeWork { ForgeWork(forges: d.forges, workspaces: d.workspaces) } }
extension Upgrade: DaemonService {
    static func of(_ d: Daemon) -> Upgrade {
        let root = d.root, offloads = d.offloads
        return Upgrade(executable: Daemon.executable, root: root, adoptable: { Handover.adoptable(Daemon.executable, home: root) },
                       waitIdle: { offloads.waitIdle(seconds: 5) }) { [weak d] in d?.upgrade(checked: true) }
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
    func handle(_ s: Service) throws -> Result
    func handle(_ s: Service, conn: Int) throws -> Result
}

extension Handled {
    static var inOrder: Bool { false }
    static var quick: Bool { false }
    func handle(_ s: Service, conn: Int) throws -> Result { try handle(s) }

    /// On the calling thread: an in-order method's, on the reader thread.
    static func answerNow(_ p: JSONValue, _ d: Daemon, conn: Int) throws -> Data {
        try Sessions.$asker.withValue(d.sessions.callers.caller(conn).origin) {
            try JSONEncoder().encode(checked(p, d, conn: conn).handle(Service.of(d), conn: conn))
        }
    }
    static func answer(_ p: JSONValue, _ d: Daemon, conn: Int) async throws -> Data { try await d.offload(quick: quick) { try answerNow(p, d, conn: conn) } }
}

/// A method that waits on a web API (Linear, Jira, Bitbucket): async, with its gh / git calls through `offload`.
/// `handle(_:conn:)` for one that reports progress to the asking connection (repo.clone).
protocol AsyncHandled: Answered {
    associatedtype Service: DaemonService
    func handle(_ s: Service) async throws -> Result
    func handle(_ s: Service, conn: Int) async throws -> Result
}

extension AsyncHandled {
    static var inOrder: Bool { false }
    func handle(_ s: Service, conn: Int) async throws -> Result { try await handle(s) }

    static func answer(_ p: JSONValue, _ d: Daemon, conn: Int) async throws -> Data {
        try await Sessions.$asker.withValue(d.sessions.callers.caller(conn).origin) {
            try JSONEncoder().encode(await checked(p, d, conn: conn).handle(Service.of(d), conn: conn))
        }
    }
}

extension RPCMethod {
    /// The method's params as its type; a bad or missing field is the caller's error.
    static func decoded(_ p: JSONValue) throws -> Self {
        do { return try (p == .null ? .object([:]) : p).decode(Self.self) }
        catch DecodingError.keyNotFound(let k, _) { throw RPCError.invalidParams("missing \(k.stringValue)") }
        catch { throw RPCError.invalidParams("\(name): \(error)") }
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
    func allow(_ m: any Answered, conn: Int, caller known: Caller? = nil) throws {
        if let refusal = m.onlyFromKelp { try clients.requireApp(conn, refusal) }
        let caller = known ?? sessions.callers.caller(conn)
        switch caller {
        case .user: return
        case .session(let own):
            if let id = m.reportsFor, own != id { throw RPCError.refused("A session speaks only for itself.") }
            guard try sessions.store.forAnAgent(own) else { return }
            try allowAgent(m, own: own)
        case .typedAgent(let own):
            if let id = m.reportsFor, own != id { throw RPCError.refused("A session speaks only for itself.") }
            try allowAgent(m, own: own, typed: true)
        case .unknown:
            // Looked up as it connects, a hook waiting for its answer is always found: one gone by then handed its
            // connection on, which is how a program would speak for a session not its own.
            try allowAgent(m, own: Sessions.unknown, or: "Kelp couldn't tell which program sent this (it ended as it connected), so it may not do that.")
        case .kelpd:
            try allowAgent(m, own: Sessions.ownProgram,
                           or: "A program Kelp runs (an extension's command or event, a repo's git hook) may not do that: it has no session to act for.")
        case .detached:
            try allowAgent(m, own: Sessions.detached,
                           or: "Kelp can't tell this program is yours (it runs outside every terminal and app: in the background, "
                               + "a launchd job, a tmux pane out of sight), so it's held to an agent's rules: run it from a terminal of yours.")
        }
    }

    /// One with no session of its own (`Caller.kelpd` and the like): no report, and an agent's rules. Refused in `why`'s
    /// words, then the rule's own (`SessionCreate`'s tmux…); anything else (the store) as it is.
    private func allowAgent(_ m: any Answered, own: String, or why: String) throws {
        if m.reportsFor != nil { throw RPCError.refused(why) }
        do { try allowAgent(m, own: own) } catch let e as RPCError where e.isRefusal {
            throw RPCError.refused(why + " " + e.message)
        }
    }

    /// What a program of an agent's (or of the daemon's, `own` = `Sessions.ownProgram`) may not do.
    /// `typed`: an agent the user typed into `own`, a terminal of theirs: what it reaches is what it started there
    /// (`typed:` on its line), not everything the user started from that terminal.
    private func allowAgent(_ m: any Answered, own: String, typed: Bool = false) throws {
        if m.signs, m.reportsFor == nil {
            throw RPCError.refused("What an agent writes for others says it's an agent's: run it from the agent's terminal, which names its session.")
        }
        func reaches(_ id: String) throws -> Bool {
            try sessions.store.lineage(id).contains { typed ? Caller.started($0.origin, byAgentTypedInto: own) : $0.id == own }
        }
        if let refusal = m.notForAgents { throw RPCError.refused(refusal) }
        if m.answersQuestion {
            throw RPCError.refused("An agent's question is the user's to answer: in Kelp's window, or `kelp agents` in a terminal of theirs.")
        }
        let name = type(of: m).name
        guard AgentRules.methods.contains(name) else {
            throw RPCError.refused("“\(name)” is the user's: an agent's program may call only what agents use (AgentRules.methods).")
        }
        if let id = m.typesInto, sessions.existing(id)?.asksSomething == true {
            throw RPCError.refused("That session asks a question, the user's to answer; send again once it's answered.")
        }
        // A typed agent's own session is the user's terminal it was typed into: it names it as anyone in it would (a child's
        // parent, its reports, its tab), but neither types into it nor acts on it (Stop, Restart, a question there).
        func itsOwn(_ id: String) -> Bool { id == own && !(typed && (id == m.typesInto || id == m.actsOn)) }
        for id in Set([m.actsOn, m.shows].compactMap { $0 } + (try sessions.named(by: m))) where !itsOwn(id) {
            guard try reaches(id) else {
                throw RPCError.refused("An agent acts only on its own session and the sessions it started.")
            }
        }
        // Every workspace a call that acts names, whatever the field: not each method remembering to say (`inWorkspace`
        // says it for one named some other way, by a path or a name).
        let workspaces = Set([m.inWorkspace].compactMap { $0 } + (AgentRules.reads.contains(name) ? [] : try sessions.workspaces(namedBy: m)))
        for w in workspaces where try !sessions.works(own, in: w, typed: typed) {
            throw RPCError.refused("An agent works only in its own workspace.")
        }
        if let e = m.ends, try sessions.ending(e).contains(where: { s in try (typed || s != own) && !reaches(s) }) {
            throw RPCError.refused("An agent ends only its own sessions and the ones it started.")
        }
    }

    /// Every method the daemon answers, by name: one list, so none is answered twice (a second entry traps at launch).
    static let methods: [String: any Answered.Type] = {
        let sync: [any Handled.Type] = Methods.miscMethods + Methods.gitMethods + Methods.workspaceMethods + Methods.sessionMethods
            + Methods.integrationMethods + Methods.projectMethods
            + Methods.launchMethods + Methods.uiMethods + Methods.lspMethods + Methods.extensionMethods + Methods.vmMethods
        let async = Methods.asyncMethods + Methods.lspAsyncMethods + Methods.uiAsyncMethods
        let all = sync.map { $0 as any Answered.Type } + async.map { $0 as any Answered.Type }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }()

    /// The reply's result, encoded once.
    func answer(_ method: String, _ p: JSONValue, conn: Int) async throws -> Data {
        guard let t = Self.methods[method] else { throw RPCError.methodNotFound }
        if let quiet = try refuseRemoteForge(t, p) { return quiet }
        return try await integrationErrors { try await gitErrors { try await t.answer(p, self, conn: conn) } }
    }

    /// An in-order method, here on the connection's reader thread, where everything sent after it waits: it starts no
    /// program (`Subprocess.quickOnly` refuses one, so the call fails at once instead of holding up the connection), and
    /// one that still took long says so in the log.
    func answerNow(_ t: any Handled.Type, _ p: JSONValue, conn: Int) throws -> Data {
        if let quiet = try refuseRemoteForge(t, p) { return quiet }
        let start = DispatchTime.now()
        defer {
            let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            if ms >= 100 { Log.rpc.error("in-order \(t.name, privacy: .public) held its connection for \(ms) ms") }
        }
        do { return try Subprocess.quickOnly { try t.answerNow(p, self, conn: conn) } } catch let e as GitError { throw RPCError.internalError(e.message) }
    }

    /// The same as a value, for callers that read it by hand (tests).
    func handle(_ method: String, _ p: JSONValue, conn: Int) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await answer(method, p, conn: conn))
    }

    private func gitErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as GitError { throw RPCError.internalError(e.message) }
    }

    /// The integrations' own errors, as the app shows them.
    private func integrationErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let e as GitHubError { throw RPCError.internalError(e.description) }
        catch let e as IntegrationError { throw RPCError.internalError(e.description) }
    }

    /// gh / glab run in the folder here; a remote project's is only a marker under ~/.kelp, and their git would walk up to
    /// whatever repository holds it (a dotfiles home). Until they run on the host, they don't run at all: a `LocalForge`
    /// method is refused for one, or answers null when the sidebar asked by itself.
    private func refuseRemoteForge(_ t: any Answered.Type, _ p: JSONValue) throws -> Data? {
        guard let forge = t as? any LocalForge.Type, (try? store.repoPath(p)).map({ remotes.of($0.1) != nil }) == true else { return nil }
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

extension DaemonBackgroundAllowed: Handled {
    /// Off the reader: each `status` waits for the system. A kelpd outside an app (a build's) has no such switch.
    func handle(_: NoService) throws -> Bool {
        let app = Bundle.main.bundleURL, suffix = (Bundle.main.bundleIdentifier ?? "").dropFirst("dev.kelp.app".count)
        guard app.pathExtension == "app" else { return true }
        return SMAppService.agent(plistName: "dev.kelp.kelpd\(suffix).plist").status != .requiresApproval
    }
}

extension DaemonInfo: Handled {
    static var quick: Bool { true }
    func handle(_ sessions: Sessions) throws -> Result {
        Result(path: URL(fileURLWithPath: Daemon.executable).resolvingSymlinksInPath().path, binaryMTime: Daemon.binaryMTime, pid: Int(getpid()),
               liveSessions: sessions.live.all.filter { $0.snapshot.status != .exited }.count)
    }
}
