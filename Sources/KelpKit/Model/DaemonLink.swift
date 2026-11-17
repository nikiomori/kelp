import AppKit
import Core
import DesignKit

/// The app's connection to kelpd. It opens the connection (starting kelpd when it isn't running), notices when kelpd
/// ended or hung, and handles a kelpd update and restart. What a new connection reads is up to the model
/// (`AppModel.opened`).
@MainActor
final class DaemonLink {
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    /// The connection that calls go through, or nil while there is none.
    private(set) var client: RPCClient?
    /// Uses a connection opened elsewhere (by a test), or none, instead of opening one here.
    func use(_ c: RPCClient?) { client = c }

    /// Connects to kelpd, one connection at a time. Launch, a dropped connection and Restart Background Service all
    /// come through here.
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
        BackgroundItem.register()   // before the first quit, which ends what the app started unless it has the item
        // kelpd is launched again on each try. A daemon that's stopping (for a restart or an update) closes its socket
        // first and holds its home's lock until its agents are gone (up to 3 s), so a kelpd started meanwhile finds
        // the lock taken and exits. A kelpd that's already running takes no harm, because a second one exits at once.
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
            // It keeps trying, less and less often, and every action meanwhile says why it does nothing.
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
        // Listen before anything that waits (the version check can show a sheet), so a daemon that drops meanwhile is
        // still noticed.
        let stopListening = app.listen(connection)
        connection.onClose = { [weak self] in
            stopListening()
            Task { @MainActor in
                // when a newer connection took over, there is nothing to undo
                guard let self, self.client === connection else { return }
                self.client = nil
                self.app.connected = false
                self.reconnectSoon()
            }
        }
        if await checkDaemonVersion(connection) { return }
        // The connection may have dropped while the update question waited for an answer. The reconnect that noticed it
        // waited for this call, so this call tries again rather than load lists over a connection that's gone.
        guard client === connection else { return reconnectSoon() }
        await app.opened(connection)
        if client === connection { watchLife(connection) }
    }

    static let noService = String(localized: "Kelp's background service isn't running.")
    /// Returns what the banner says when kelpd doesn't answer. That is why kelpd didn't start (from `kelpd.err`, which
    /// kelpd leaves for this) and the command that fixes it when one is known. Without a reason, it says only that the
    /// service isn't running.
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

    /// Watches for a hung kelpd. A connected kelpd that hangs never says so: quiet reads stay quiet, and a person's
    /// action waits for minutes. Two checks in a row without an answer show a banner with the way out. A connection
    /// that ended is handled by `onClose`.
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

    static func answers(_ client: RPCClient, within seconds: TimeInterval) async -> Bool {
        do {
            _ = try await client.call(DaemonInfo(), timeout: seconds)
            return true
        } catch { return (error as? RPCError)?.isNoReply != true }
    }

    /// Checks the daemon's version, because after an app update the running daemon may be older. The daemon takes the
    /// update in place when it can (`daemon.upgrade`, so agents keep running). Otherwise it restarts right away when no
    /// agent is running, and else Kelp asks first, because restarting ends running sessions. Returns true when an
    /// upgrade or a restart is in progress.
    private func checkDaemonVersion(_ c: RPCClient) async -> Bool {
        guard
            let mine =
                (try? FileManager.default.attributesOfItem(atPath: bundledDaemon.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970
        else { return false }
        let info: DaemonInfo.Result
        do { info = try await c.call(DaemonInfo()) } catch {
            // It is connected but doesn't answer. The lists asked for next would leave an empty window for minutes,
            // with no word why, so say so now.
            if (error as? RPCError)?.isNoReply == true { sayNotAnswering() }
            return false
        }
        // Older daemons don't report binaryMTime (their "mtime" was read from disk, so it is already the new file's),
        // so they are restarted.
        let samePath = info.path == bundledDaemon.resolvingSymlinksInPath().path
        guard !(samePath && abs((info.binaryMTime ?? 0) - mine) < 1), !restartAttempted else { return false }
        restartAttempted = true   // one try per launch, so a daemon too old to shut down is left running, not looped on
        // A daemon that can run the new binary at its own path, in place, keeps every agent running. An older one (or
        // one from another copy of Kelp) has to restart.
        // A refusal says why (the new kelpd can't take the sessions over), and the user hears it with the question.
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
                // Return keeps the agents running, so ending them takes a deliberate click.
                alert.buttons[0].hasDestructiveAction = true
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[1].keyEquivalent = "\r"
                guard await runSheet(alert) == .alertFirstButtonReturn else { return false }
            }
            // A daemon too old to take daemon.shutdown is stopped by signal, or else the reconnect finds it again.
            do { _ = try await c.call(DaemonShutdown()) } catch { if let pid = c.daemonPID { await Self.stop(pid) } }
        }
        c.close()
        client = nil
        try? await Task.sleep(for: .milliseconds(600))
        await open()
        return true
    }

    /// Restarts the background service with every agent still running, by having kelpd run itself again in place
    /// (`daemon.upgrade`). When kelpd can't, this throws the reason and nothing has changed.
    func upgrade() async throws {
        guard let old = client else { throw RPCError.internalError(Self.noService) }
        _ = try await old.call(DaemonUpgrade())
        await reconnect(after: detach())
    }

    /// Restarts the background service by stopping and starting it, which ends the agents.
    func restart() async {
        let old = detach()
        // A hung daemon that doesn't answer is stopped by signal, or else the reconnect finds it again, still holding
        // the socket.
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

    /// Stops a kelpd that didn't take daemon.shutdown, with SIGTERM and then SIGKILL after 2 s. It signals only a
    /// process that still runs kelpd, so a pid reused meanwhile is left alone.
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
    /// Why kelpd couldn't be started at all (it isn't there, or isn't allowed to run). In that case kelpd leaves no
    /// kelpd.err to say so itself.
    private var launchFailure: String?
}
