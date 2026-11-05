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
        try Sessions.$asker.withValue(d.sessions.caller(conn)) {
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
        try await Sessions.$asker.withValue(d.sessions.caller(conn)) {
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
    /// counts, so a method needn't remember to say so. A program the daemon started (an extension's, a git hook) is held
    /// to the same with no session of its own. The user's own terminals drive any. Limit: a program that left the tree
    /// and its terminal (`setsid`, a tmux server) is taken for one outside every session, and an agent typed into a
    /// plain terminal by hand counts as that terminal; macOS doesn't show another process's environment (its
    /// KELP_SESSION) to tell, and an agent can still leave a program for the user to run (a file): the socket, and the
    /// files, are the user's.
    func allow(_ m: any Answered, conn: Int) throws {
        if let refusal = m.onlyFromKelp { try clients.requireApp(conn, refusal) }
        guard let own = sessions.caller(conn) else { return }
        if let id = m.reportsFor, own != id { throw RPCError.invalidParams("A session speaks only for itself.") }
        guard own != Sessions.inside else {
            do { return try allowAgent(m, own: own) } catch {
                throw RPCError.invalidParams("A program Kelp runs (an extension's command or event, a repo's git hook) may not do that: it has no session to act for.")
            }
        }
        guard try sessions.forAnAgent(own) else { return }
        try allowAgent(m, own: own)
    }

    /// What a program of an agent's (or of the daemon's, `own` = `Sessions.inside`) may not do.
    private func allowAgent(_ m: any Answered, own: String) throws {
        if let refusal = m.notForAgents { throw RPCError.invalidParams(refusal) }
        if m.answersQuestion {
            throw RPCError.invalidParams("An agent's question is the user's to answer: in Kelp's window, or `kelp agents` in a terminal of theirs.")
        }
        if let id = m.typesInto, sessions.existing(id)?.snapshot.status == .waiting {
            throw RPCError.invalidParams("That session asks a question, the user's to answer; `kelp session send` types once it's answered.")
        }
        for id in Set([m.actsOn].compactMap { $0 } + (try sessions.named(by: m))) where id != own {
            guard try sessions.lineage(id).contains(where: { $0.id == own }) else {
                throw RPCError.invalidParams("An agent acts only on its own session and the sessions it started.")
            }
        }
        if let w = m.inWorkspace, try !sessions.works(own, in: w) {
            throw RPCError.invalidParams("An agent works only in its own workspace.")
        }
        if let e = m.ends, try sessions.ending(e).contains(where: { s in try !sessions.lineage(s).contains { $0.id == own } }) {
            throw RPCError.invalidParams("An agent ends only its own sessions and the ones it started.")
        }
    }

    /// Every method the daemon answers, by name: one list, so none is answered twice (a second entry traps at launch).
    static let methods: [String: any Answered.Type] = {
        let sync: [any Handled.Type] = [DaemonInfo.self, DaemonBackgroundAllowed.self, StateGet.self, StateSet.self, SessionRename.self,
                                        SessionMove.self, SessionContextWindow.self, SessionContextParts.self,
                                        SessionSubagentSteps.self, SessionSubagentJournal.self,
                                        WorktreeNote.self, RepoWorktreeSizes.self, RepoRemoveWorktrees.self, GitDiscardHunk.self,
                                        RemoteListFolders.self, SessionReport.self, PaneReportAgent.self, ClientEvents.self, WatchStart.self, WatchStop.self,
                                        RoutineList.self, RoutineSet.self, RoutineDelete.self, RoutineRun.self]
            + Methods.gitMethods + Methods.workspaceMethods + Methods.sessionMethods + Methods.integrationMethods + Methods.projectMethods
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

/// At most `limit` holders at once; the rest wait first come, first served, suspended (no thread held while waiting).
/// Limit: a waiter whose task is cancelled still takes its turn; nothing here cancels (a client's deadline is its own).
final class Slots: Sendable {
    let limit: Int
    private struct State { var held = 0, closed = false; var waiting: [CheckedContinuation<Bool, Never>] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Quick work's own cap (a thread each): it never waits behind slow work, only behind this much quick work at once,
    /// so a client looping on `kelp hook` can't make thousands of threads.
    private let quickSlots: Slots?
    /// `runNow`'s own cap: never behind slow work, and a client looping on attach can't make a thread per call.
    private let nowSlots: Slots?
    init(_ limit: Int, quick: Int? = 64) {
        self.limit = limit
        quickSlots = quick.map { Slots($0, quick: nil) }
        nowSlots = quick.map { Slots($0 / 2, quick: nil) }
    }

    /// False once closed (`close`): no slot is given from then on.
    func acquire() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let now = state.withLock { s -> Bool? in
                if s.closed { return false }
                guard s.held < limit else { s.waiting.append(c); return nil }
                s.held += 1; return true
            }
            if let now { c.resume(returning: now) }
        }
    }

    /// The slot passes straight to the longest waiter, if there is one.
    func release() {
        let next = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            guard !s.waiting.isEmpty else { s.held -= 1; return nil }
            return s.waiting.removeFirst()
        }
        next?.resume(returning: true)
    }

    /// An update is on its way: work that has a slot finishes (`waitIdle`), none starts, what waits is refused.
    func close() {
        let refused = state.withLock { s in
            defer { s.waiting = [] }
            s.closed = true
            return s.waiting
        }
        refused.forEach { $0.resume(returning: false) }
        quickSlots?.close()
        nowSlots?.close()
    }

    /// `work` on a thread of its own, programs allowed: what the user is waiting to see (a paused agent's tab waking)
    /// doesn't queue behind slow git or ssh, only behind as much of its own kind as its cap allows.
    func runNow<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        if let nowSlots { return try await nowSlots.run(work) }
        return try await Self.onThread { Result(catching: work) }
    }

    /// Waits until no slot is held (what's running has finished), for at most `seconds`: looked at every 50 ms, which an
    /// update (the one caller) can afford. Work that keeps coming keeps it waiting to the end, as it should.
    func waitIdle(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while busy, Date() < end { usleep(50_000) }
    }
    /// A slot is held here or by a wake (`runNow`: it starts programs too).
    private var busy: Bool { state.withLock { $0.held > 0 } || nowSlots?.busy == true
    }

    /// `work` on a thread of its own once it has a slot (`Daemon.offload`); `quick`, at once, with no slot and no program.
    func run<T: Sendable>(quick: Bool = false, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let slots = quick ? quickSlots : self, asker = Sessions.asker   // a thread of its own doesn't inherit it
        if let slots, await !slots.acquire() { throw RPCError.updating }
        return try await Self.onThread {
            defer { slots?.release() }
            return Sessions.$asker.withValue(asker) { quick ? Result { try Subprocess.quickOnly(work) } : Result(catching: work) }
        }
    }

    /// `body` on a thread of its own, its result handed back under a lock: what it made (a woken session) is seen whole
    /// by whoever reads it after. The continuation alone would order it too, but the Thread Sanitizer can't see that
    /// (Swift's concurrency library isn't built for it) and reported the session's fields as a race.
    private static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> Result<T, Error>) async throws -> T {
        let handed = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread {
                let r = body()
                handed.withLock { $0 = r }
                c.resume()
            }
        }
        guard let r = handed.withLock({ $0 }) else { throw RPCError.internalError("no result") }
        return try r.get()
    }
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

extension GitDiscardHunk: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        let w = try workspaces.store.worktree(named: id)
        guard let diff = try Git.diff(w.path, source: .unstaged, file: file, remotes: workspaces.remotes).first, diff.hunks.indices.contains(hunk),
              diff.hunks[hunk].header == header, fingerprint.map({ $0 == diff.hunks[hunk].fingerprint }) ?? true else {
            throw RPCError.invalidParams("The file changed since it was shown; nothing was discarded.")
        }
        try Git.discardHunk(w.path, diff: diff, hunk: hunk, remotes: workspaces.remotes)
        workspaces.keepDiscard(.init(patch: diff.patch(hunk: hunk), hunk: true), folder: w.path, name: undo)
        return Done()
    }
}

extension WorktreeNote: Handled {
    func handle(_ workspaces: Workspaces) throws -> Done {
        guard try workspaces.store.update(Worktree.self, id, { $0.note = note }) != nil else { throw RPCError.invalidParams("no worktree") }
        workspaces.notify(ChangedEvent.worktree); return Done()
    }
}

extension RepoWorktreeSizes: Handled {
    func handle(_ workspaces: Workspaces) throws -> [Item] {
        guard let r = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        guard workspaces.remotes.of(r.path) == nil else { return [] }   // their disk is on the host
        let ours = try Self.ours(workspaces.store, r)
        return try Git.linkedWorktrees(r.path, remotes: workspaces.remotes).filter { FileManager.default.fileExists(atPath: $0.path) }.map { w in
            Item(path: w.path, bytes: Self.du(w.path),
                 removable: !w.locked && !ours.contains(Self.real(w.path)) && (try? Git.isDirty(w.path, remotes: workspaces.remotes)) == false
                    && Git.commitsOnNoBranch(w.path, remotes: workspaces.remotes) == 0)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Kelp's own worktree workspaces (from older versions): git prints real paths, the store keeps them as created.
    static func ours(_ store: Store, _ r: Repo) throws -> Set<String> { Set(try store.worktrees(repo: r.id).map { real($0.path) }) }
    static func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }

    /// Blocks on disk as `du` counts them (16 GB of build products: about a second); unreadable files leave out only themselves.
    static func du(_ path: String) -> Int {
        let out = (try? Git.run(["-sk", path], cwd: path, executable: "/usr/bin/du", ok: [0, 1])) ?? ""
        return (Int(out.prefix { $0.isNumber }) ?? 0) * 1024
    }
}

extension RepoRemoveWorktrees: Handled {
    func handle(_ workspaces: Workspaces) throws -> Result {
        guard let r = try workspaces.store.repo(id) else { throw RPCError.invalidParams("no repo") }
        let linked = try Git.linkedWorktrees(r.path, remotes: workspaces.remotes), ours = try RepoWorktreeSizes.ours(workspaces.store, r)
        var out = Result(removed: [], kept: [:])
        // A paused agent comes back where it last worked: its folder is as much in use as a running one's.
        let stored = try workspaces.store.sessions().filter { $0.status != .exited }.map(\.currentDir)
        let inUse = workspaces.sessions.live.all.map(\.snapshot.currentDir) + stored
        for p in paths {
            guard let w = linked.first(where: { $0.path == p }), !ours.contains(RepoWorktreeSizes.real(p)) else {
                out.kept[p] = "Not one of the project's other worktrees."; continue
            }
            // Nothing in it yet is what a worktree an agent just made looks like: its folder would go from under it.
            let real = RepoWorktreeSizes.real(p) + "/"
            if inUse.contains(where: { (RepoWorktreeSizes.real($0) + "/").hasPrefix(real) }) {
                out.kept[p] = "An agent works in it."; continue
            }
            // git removes one whose commits are on no branch (a detached HEAD): they'd be left to `git gc`.
            if case let n = Git.commitsOnNoBranch(p, remotes: workspaces.remotes), n > 0 {
                out.kept[p] = "It has \(n) commit\(n == 1 ? "" : "s") on no branch (a detached HEAD)."; continue
            }
            do {
                // Kept with changes, untracked files or a lock; else the folder goes to the Trash, ignored files (.env, a
                // local database) and all, which `git worktree remove` would delete for good. Its branch stays: below.
                try Git.removeWorktree(repo: r.path, path: p, branch: nil, force: false, remotes: workspaces.remotes)
                if let b = w.branch, Git.isRevision(b) {   // -d: only if its commits are on another branch
                    _ = Log.store.attempt("deleting merged branch \(b)") { try Git.run(["branch", "-d", b], cwd: r.path, remotes: workspaces.remotes) }
                }
                out.removed.append(p)
            } catch let e as GitError { out.kept[p] = e.message } catch { out.kept[p] = error.localizedDescription }
        }
        return out
    }
}

extension SessionReport: Handled {
    var reportsFor: String? { id }
    static var quick: Bool { true }   // `kelp report`: the agent waits for it
    func handle(_ sessions: Sessions) throws -> Done {
        guard ProgramStatus.states.contains(state) else { throw RPCError.invalidParams("state is one of idle, working, blocked, done, error, clear") }
        guard let ls = sessions.existing(id) else { return Done() }   // ended or paused: there's nothing to show it on
        let r = ProgramStatus.Report(state: state, kind: state == "blocked" ? kind : nil, msg: message,
                                     progress: state == "working" ? progress.map { min(100, max(0, $0)) } : nil)
        if ls.report(r) != nil { sessions.publish(ls) }
        return Done()
    }
}

/// herdr has no "done": idle after work is a finished turn (`StatusDetector.program`).
extension PaneReportAgent: Handled {
    var reportsFor: String? { paneId }
    static var quick: Bool { true }   // fx waits for the reply
    func handle(_ sessions: Sessions) throws -> Done {
        guard ["idle", "working", "blocked"].contains(state) else { throw RPCError.invalidParams("state is one of idle, working, blocked") }
        guard let ls = sessions.existing(paneId) else { return Done() }
        if ls.report(ProgramStatus.Report(state: state)) != nil { sessions.publish(ls) }
        return Done()
    }
}

extension SessionContextWindow: Handled {
    func handle(_ sessions: Sessions) throws -> Usage? {
        guard let t = sessions.existing(id).flatMap(sessions.agentUsage.transcript(of:)), let c = AgentUsage.contextUsage(transcript: t) else { return nil }
        return Usage(used: c.used, window: sessions.agentUsage.contextWindow(model: c.model, peak: c.peak), cacheUntil: c.cacheUntil)
    }
}

extension RoutineList: Handled { func handle(_ w: Workspaces) throws -> RoutinesEvent { try w.routines.list() } }
extension RoutineSet: Handled {
    /// A routine starts agents later, from nobody's session: what an agent set up would run as the user's own.
    static let theUsers = "A routine is the user's to set up: in Kelp's window (Routines), or `kelp routine` in a terminal of theirs."
    var notForAgents: String? { Self.theUsers }
    func handle(_ w: Workspaces) throws -> Routine { try w.routines.set(routine) }
}
extension RoutineDelete: Handled {
    var notForAgents: String? { RoutineSet.theUsers }
    func handle(_ w: Workspaces) throws -> Done {
        try w.routines.delete(id)
        return Done()
    }
}
extension RoutineRun: Handled { func handle(_ w: Workspaces) throws -> Routine.Run { try w.routines.runNow(id, workspaces: w) } }

extension SessionContextParts: Handled {
    func handle(_ sessions: Sessions) throws -> Parts? {
        guard let ls = sessions.existing(id), let t = sessions.agentUsage.transcript(of: ls), let c = AgentUsage.contextUsage(transcript: t),
              var parts = ClaudeContext.parts(try Data(contentsOf: t, options: .mappedIfSafe), used: c.used) else { return nil }
        parts.setup = sessions.claudeSetup(ls.snapshot).map { ClaudeContext.fit($0, to: parts.base) }
        return parts
    }
}

extension SessionSubagentSteps: Handled {
    func handle(_ sessions: Sessions) throws -> Result {
        guard let ls = sessions.existing(id), let parent = sessions.agentUsage.transcript(of: ls) else { return [:] }
        var last: Result = [:]
        for run in ls.snapshot.runningSubagents {
            guard let file = SubagentTranscript.file(parent: parent, id: run.id), let tail = Data(tailOf: file, bytes: 262_144),
                  let step = SubagentTranscript.lastStep(tail: tail),
                  let touched = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            last[run.id] = Last(step: step, touched: touched)
        }
        return last
    }
}

extension SessionSubagentJournal: Handled {
    func handle(_ sessions: Sessions) throws -> Result {
        let usage = sessions.agentUsage
        guard let parent = try sessions.existing(id).flatMap(usage.transcript(of:)) ?? sessions.store.session(id).flatMap(usage.transcript(of:)),
              let file = SubagentTranscript.file(parent: parent, id: subagent),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try SubagentTranscript.journal(file)
    }
}

extension Data {
    /// The file's last `bytes` (all of it when shorter); nil when it can't be opened.
    init?(tailOf url: URL, bytes: Int) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        self = (try? h.readToEnd()) ?? Data()
    }
}

extension Sessions {
    /// The sessions removing `e` ends: those of the workspace, or of every workspace of the project.
    /// The sessions a call names, in any field (an `id`, a `session`, a `parent`, a list of them): what an agent's call
    /// may reach is decided by what it names, not by each method remembering to say.
    func named(by m: any Answered) throws -> [String] {
        let ids = Mirror(reflecting: m).children.flatMap { c -> [String] in
            if let s = c.value as? String { return [s] }
            return c.value as? [String] ?? []
        }
        return try ids.filter { UUID(uuidString: $0) != nil }.filter { try store.session($0) != nil }
    }

    /// Whether `w` is the workspace of `own`, of one that started it, or of one it started: an agent works there only.
    func works(_ own: String, in w: String) throws -> Bool {
        if try lineage(own).contains(where: { $0.worktreeId == w }) { return true }
        return try store.sessions().contains { s in try s.worktreeId == w && lineage(s.id).contains { $0.id == own } }
    }

    func ending(_ e: Ending) throws -> [String] {
        let ids: Set<String> = switch e {
        case .workspace(let w): [w]
        case .project(let r): Set(try store.worktrees(repo: r).map(\.id))
        }
        return try store.sessions().filter { ids.contains($0.worktreeId ?? "") }.map(\.id)
    }
}
