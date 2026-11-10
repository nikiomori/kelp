import AppKit
import Core
import DesignKit

/// The app's connection to kelpd: opens it (starting kelpd when it isn't running), notices one that ended or hung, takes
/// an update of kelpd over and restarts it. What a new connection reads is the model's (`AppModel.opened`).
@MainActor
final class DaemonLink {
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    /// The connection calls go through; nil while there's none.
    private(set) var client: RPCClient?
    /// A connection opened elsewhere (a test's), or none, in place of this one's.
    func use(_ c: RPCClient?) { client = c }

    /// One connection at a time: launch, a dropped connection and Restart Background Service all come through here.
    func connect() async {
        if client != nil { return }
        if let running = connecting { return await running.value }
        let task = Task { await open() }
        connecting = task
        await task.value
        connecting = nil
    }
    private var connecting: Task<Void, Never>?
    private var retryDelay = 1.0
    private var failing = false

    private func open() async {
        BackgroundItem.register()   // before the first quit: what the app started is ended then unless it has the item
        // Launched again on each try: a daemon that's stopping (a restart, an update) closes its socket first and holds
        // its home's lock until its agents are gone (up to 3 s), so the kelpd started meanwhile finds it taken and exits.
        // One that's already running takes no harm: a second kelpd exits at once.
        for _ in 0..<3 {
            if let opened = try? RPCClient(socket: Paths.socket.path) {
                client = opened
                break
            }
            launchDaemon()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                if let opened = try? RPCClient(socket: Paths.socket.path) {
                    client = opened
                    break
                }
            }
            if client != nil { break }
        }
        guard let connection = client else {
            // Keeps trying (less and less often); every action meanwhile says why it does nothing.
            if !failing {
                failing = true
                Banner.show(
                    launchFailure.map { Self.noService + " " + $0 } ?? Self.whyNoService(), style: .error,
                    action: (String(localized: "Try Again"), { Task { await self.connect() } }))
            }
            reconnectSoon()
            return
        }
        retryDelay = 1
        failing = false
        // Before anything that waits (the version check can show a sheet): a daemon that drops meanwhile is still noticed.
        let stopListening = app.listen(connection)
        connection.onClose = { [weak self] in
            stopListening()
            Task { @MainActor in
                // a newer connection took over: nothing to undo
                guard let self, self.client === connection else { return }
                self.client = nil
                self.app.connected = false
                self.reconnectSoon()
            }
        }
        if await checkDaemonVersion(connection) { return }
        // Dropped while the update's question waited for an answer: the reconnect that noticed waited for this, so this one
        // tries again rather than load lists over a connection that's gone.
        guard client === connection else { return reconnectSoon() }
        await app.opened(connection)
        if client === connection { watchLife(connection) }
    }

    static let noService = String(localized: "Kelp's background service isn't running.")
    /// What the banner says when kelpd doesn't answer: why it didn't start (`kelpd.err`, which it leaves for this), and the
    /// command that fixes it when one is known; without one, only that it isn't running.
    static func whyNoService(root: URL = Paths.root) -> String {
        let why =
            (try? String(contentsOf: Paths.daemonError(in: root), encoding: .utf8))?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
        guard !why.isEmpty else { return noService }
        return noService + " " + why
            + (FixRecipes.fix(for: why).map { " " + String(localized: "Fix it in Terminal: \($0.command)") } ?? "")
    }

    private var restartAttempted = false
    /// Where kelpd and kelp sit next to the app binary.
    private var binDir: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
    }
    private var bundledDaemon: URL { binDir.appendingPathComponent("kelpd") }

    private func sayNotAnswering() {
        Banner.show(
            String(localized: "Kelp's background service isn't answering."), style: .error,
            action: (String(localized: "Restart It"), { Task { await self.restart() } }))
    }

    /// A kelpd that's connected and hung never says so: what's quiet stays quiet, and a person's action waits for minutes.
    /// Two looks in a row without an answer say so, with the way out. A connection that ended is `onClose`'s.
    private func watchLife(_ c: RPCClient) {
        Task { [weak self] in
            var missed = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, client === c else { return }
                missed = await Self.answers(c, within: 10) ? 0 : missed + 1
                if missed == 2 { sayNotAnswering() }
            }
        }
    }

    static func answers(_ c: RPCClient, within seconds: TimeInterval) async -> Bool {
        do {
            _ = try await c.call(DaemonInfo(), timeout: seconds)
            return true
        } catch { return (error as? RPCError)?.isNoReply != true }
    }

    /// After an app update the running daemon may be older. It takes the update over in place when it can (`daemon.upgrade`:
    /// agents keep running); else it restarts right away when no agent is running, and otherwise asks, because restarting
    /// ends running sessions. Returns true when an upgrade or a restart is in progress.
    private func checkDaemonVersion(_ c: RPCClient) async -> Bool {
        guard
            let mine =
                (try? FileManager.default.attributesOfItem(atPath: bundledDaemon.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970
        else { return false }
        let info: DaemonInfo.Result
        do { info = try await c.call(DaemonInfo()) } catch {
            // Connected, and it doesn't answer: the lists asked for next would leave an empty window for minutes, with no word why.
            if (error as? RPCError)?.isNoReply == true { sayNotAnswering() }
            return false
        }
        // Older daemons don't report binaryMTime (and their "mtime" was read from disk, i.e. already the new file): restart them.
        let samePath = info.path == bundledDaemon.resolvingSymlinksInPath().path
        guard !(samePath && abs((info.binaryMTime ?? 0) - mine) < 1), !restartAttempted else { return false }
        restartAttempted = true   // one try per launch: a daemon too old to shut down is left running rather than looping
        // One that runs the new binary at its path in place keeps every agent running; an older one (or another copy of
        // Kelp's) has to restart.
        // A refusal says why (the new kelpd can't take the sessions over): the user hears it with the question.
        var upgrading = false, refusal: String?
        if samePath {
            do {
                _ = try await c.call(DaemonUpgrade())
                upgrading = true
            } catch { refusal = (error as? RPCError)?.message ?? "\(error)" }
        }
        if !upgrading {
            if info.liveSessions > 0 {
                let alert = NSAlert()
                alert.messageText = String(localized: "Kelp was updated")
                alert.informativeText =
                    (refusal.map { $0 + "\n\n" } ?? "")
                    + String(
                        localized:
                            "The background service is still the previous version. Restart it to finish the update — running agent sessions will end. You can also do it later from the Kelp menu."
                    )
                alert.addButton(withTitle: String(localized: "Restart Service"))
                alert.addButton(withTitle: String(localized: "Later"))
                // Return keeps the agents running: ending them takes a deliberate click.
                alert.buttons[0].hasDestructiveAction = true
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                guard await runSheet(alert) == .alertFirstButtonReturn else { return false }
            }
            // One too old to take daemon.shutdown is stopped, else the reconnect finds it again.
            do { _ = try await c.call(DaemonShutdown()) } catch { if let pid = c.daemonPID { await Self.stop(pid) } }
        }
        c.close()
        client = nil
        try? await Task.sleep(for: .milliseconds(600))
        await open()
        return true
    }

    /// Restart Background Service, every agent still running: kelpd runs itself again in place (`daemon.upgrade`). One that
    /// can't throws why, and nothing happened.
    func upgrade() async throws {
        guard let old = client else { throw RPCError.internalError(Self.noService) }
        _ = try await old.call(DaemonUpgrade())
        await reconnect(after: detach())
    }

    /// Restart Background Service: it stops and starts again, ending the agents.
    func restart() async {
        let old = detach()
        // One that doesn't answer (hung) is stopped: else the reconnect finds it again, still holding the socket.
        if let old {
            let pid = old.daemonPID
            do { _ = try await old.call(DaemonShutdown(), timeout: 5) } catch { if let pid { await Self.stop(pid) } }
        }
        await reconnect(after: old)
    }

    private func detach() -> RPCClient? {
        let old = client
        app.stopHearing(old)
        client = nil
        app.connected = false
        return old
    }

    private func reconnect(after old: RPCClient?) async {
        old?.close()
        try? await Task.sleep(for: .milliseconds(600))
        await connect()
    }

    /// A kelpd that didn't take daemon.shutdown: SIGTERM, then SIGKILL after 2 s. Only a process still running kelpd (a
    /// pid reused meanwhile is left alone).
    static func stop(_ pid: pid_t) async {
        guard Unix.executable(pid)?.hasSuffix("/kelpd") == true else { return }
        kill(pid, SIGTERM)
        for _ in 0..<20 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if kill(pid, 0) == 0, Unix.executable(pid)?.hasSuffix("/kelpd") == true { kill(pid, SIGKILL) }
    }

    private func reconnectSoon() {
        let wait = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        Task {
            try? await Task.sleep(for: .seconds(wait))
            await connect()
        }
    }

    private func launchDaemon() {
        let dir = binDir
        let process = Process()
        process.executableURL = dir.appendingPathComponent("kelpd")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            launchFailure = nil
        } catch { launchFailure = error.localizedDescription }
    }
    /// Why kelpd couldn't be started at all (not there, not allowed to run): it leaves no kelpd.err to say so itself.
    private var launchFailure: String?
}
