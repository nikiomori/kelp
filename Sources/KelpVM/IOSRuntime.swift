import Core
import Foundation

/// Runs an iOS machine. The machine is a simulator of the user's Xcode, named "Kelp <name>" and kept in the default
/// device set, because xcodebuild sees no other. Kelp's runner (`IOSRunner`, built into the machine's folder) runs in
/// the simulator, and agents' commands reach the runner on the Mac's loopback. A simulator can't be paused or saved,
/// so after 10 idle minutes it shuts down, and the next command boots it again (10–25 s).
@MainActor
final class IOSRuntime: MachineRuntime {
    let folder: URL, machine: VMMachine
    private(set) var state: VMState = .off
    private var runner: Process?
    private var port = 0
    /// The claim on the runner's port (`Lifecycle.claimPort`). It is held while the port may be in use, and let go
    /// when the next boot claims a port.
    private var portClaim: Int32 = -1
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = []
    /// The last shutdown asked of the simulator. A boot waits for it, because a simulator booted while that shutdown
    /// runs would be shut down again.
    private var shutdown: Task<Void, Never>?
    /// `boots` numbers each boot. A stop during a boot moves the number on, and that boot gives up at its next step.
    /// `booting` is the simctl boot under way. A shutdown waits for it, because a simulator shut down before the boot
    /// ends would come up after the stop.
    private var boots = 0, booting: Task<Void, Error>?
    private var sources: [DispatchSourceProtocol] = []
    /// How the process ends once the machine has left, what time it is, and where xcrun is. By default these are the
    /// process's exit, the clock and the system's xcrun, and a test sets its own.
    var exitProcess: () -> Void = { exit(0) }
    var now: () -> Date = { Date() }
    var xcrun = "/usr/bin/xcrun"

    private var udid: String {
        String(contentsIfAny: VMFolder(folder).udid)?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
    }

    init(folder: URL, machine: VMMachine) {
        self.folder = folder
        self.machine = machine
    }

    func listen() {
        // main.swift already holds the machine's lock.
        sources.append(
            Control.listen(VMFolder(folder).control.path) { [weak self] fd in
                guard let self else { return }
                Control.serve(fd, handle: handle, reply: reply)
            })
        sources += Control.run(
            tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.stop { self?.exitProcess() } })
        log("ready: \(machine.name) (iOS \(udid)), off")
    }

    /// Counts what uses the machine: programs that drive the simulator from outside, and kelpd's calls to the runner
    /// (kelpd's memory budget sleeps only an idle machine). kelpd's calls go straight to the runner's port, so kelp-vm
    /// doesn't see them. Each call comes right after a start (`connect`), so a start asked in the last `callWindow`
    /// counts as a call under way.
    private var using: Int {
        guard state == .running else { return 0 }
        return clients + (now().timeIntervalSince(lastStart) < Self.callWindow ? 1 : 0)
    }
    private var clients: Int { Usage.clients(of: udid, programs: Self.clients) }
    /// Limit: a runner call longer than this (a `ui` of a huge screen) may be slept under by the budget.
    static let callWindow: TimeInterval = 30
    private var lastStart = Date.distantPast

    private func reply(_ fd: Int32, _ error: String?) {
        let up = state.isUp   // never paused, because a simulator can't be
        var answer = VMHelper.Reply(
            state: state, connections: using, memoryMiB: up ? machine.memoryMiB : nil, error: error,
            serial: state == .running ? udid : nil)
        answer.port = state == .running ? port : nil
        Control.write(fd, answer)
    }

    func handle(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void) {   // internal: the tests drive it
        Lifecycle.handle(request, on: self, done)
    }

    var hasMachine: Bool { runner != nil }
    var inUse: Bool { using > 0 }
    func end() { exitProcess() }

    func used(_ request: VMHelper.Request) {
        lastUse = now()
        if request.op == .start, !request.begins { lastStart = lastUse }   // a runner call comes right after (`using`)
    }

    /// Handles a request to sleep the machine. When the budget asks while the machine is still booting, the boot goes
    /// on (its start waits on it), and the answer reports the machine as up, so the budget counts it as held. Otherwise
    /// the simulator shuts down, because it keeps no running state to save, and the next start is a new kelp-vm.
    func sleep(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void) {
        if request.ifIdle, state == .starting { return done(nil) }
        stop {
            done(nil)
            self.exitProcess()
        }
    }

    func show(_ done: @escaping (String?) -> Void) {
        wake { error in
            let simulator = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", self.udid]
            if error == nil {
                do { _ = try Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: simulator) } catch {
                    log("opening Simulator: \(error.localizedDescription)")
                }
            }
            done(error)
        }
    }

    func quit() { stop { self.exitProcess() } }

    func wake(_ done: @escaping (String?) -> Void) {
        switch state {
        case .running: done(nil)
        case .starting: ready.append(done)
        default:
            ready.append(done)
            Lifecycle.move(&state, to: .starting)
            boots += 1
            let boot = boots
            Task { await self.boot(boot) }
        }
    }

    /// Boots the simulator (a no-op when it is already booted), then starts the runner in it and waits until the runner
    /// answers. When a stop comes meanwhile (`boots` moved on), the boot goes no further, because the stop already told
    /// whoever was waiting.
    private func boot(_ number: Int) async {
        await shutdown?.value
        guard boots == number else { return }
        // A kelp-vm that was killed may have left its runner, which is ended here. The simulator is taken as it is.
        Lifecycle.endLeftover(in: folder, "runner")
        do {
            let udid = udid
            let step = Task {
                _ = try await simctl(["boot", udid], allowFailure: true)
                _ = try await simctl(["bootstatus", udid, "-b"])
            }
            booting = step
            defer { if booting == step { booting = nil } }
            try await step.value
            guard boots == number else { return }
            // With no build folder at all (making was cut short), the error says the runner isn't built, not that a
            // folder is missing.
            let products = VMFolder(folder).runnerBuild.appendingPathComponent("Build/Products")
            let built =
                FileManager.default.fileExists(atPath: products.path)
                ? try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil) : []
            guard let xctestrun = built.first(where: { $0.pathExtension == "xctestrun" }) else {
                throw VMError("Kelp's runner isn't built in \(machine.name)'s folder: make the machine again.")
            }
            close(portClaim)
            (port, portClaim) = Lifecycle.claimPort(from: 8700, in: folder.deletingLastPathComponent())
            let process = Process()
            process.executableURL = URL(fileURLWithPath: xcrun)
            process.arguments = [
                "xcodebuild", "test-without-building", "-xctestrun", xctestrun.path, "-destination", "id=\(udid)"
            ]
            var env = ProcessInfo.processInfo.environment
            env["TEST_RUNNER_KELP_PORT"] = "\(port)"
            process.environment = env
            let out = folder.appendingPathComponent("runner.log")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            do {
                let logFile = try FileHandle(forWritingTo: out)
                process.standardOutput = logFile
                process.standardError = logFile
            } catch { log("no runner.log: \(error.localizedDescription)") }
            process.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {   // DispatchQueue.main runs this on the main thread
                        guard let self, self.runner === ended else { return }
                        self.runner = nil
                        if self.state == .running {
                            // The simulator shuts down with the runner. Left booted with the machine off, it would
                            // hold its memory, and no tick would see it.
                            _ = self.shutDown()
                            Lifecycle.move(&self.state, to: .off)
                            log("the runner ended: see runner.log")
                        }
                    }
                }
            }
            try process.run()
            runner = process
            Lifecycle.remember(process.processIdentifier, in: folder, as: "runner")
            let since = Date()
            while Date().timeIntervalSince(since) < 180 {
                let answered = await ping()
                guard boots == number else { return }   // a stop ended this boot's runner
                if answered { return started(nil) }
                guard runner != nil else {
                    throw VMError("Kelp's runner quit: see runner.log in \(machine.name)'s folder.")
                }
                try await Task.sleep(nanoseconds: 50_000_000)   // a refused loopback connect costs nothing
            }
            throw VMError("Kelp's runner didn't answer in 3 minutes.")
        } catch { if boots == number { started(error) } }
    }

    private func started(_ error: Error?) {
        if let error {
            log("start failed: \(error.localizedDescription)")
            _ = shutDown()   // a half-started simulator would stay booted, as ticks skip a machine that isn't running
        }
        Lifecycle.move(&state, to: error == nil ? .running : .error)
        lastUse = now()
        ready.flush(error)
    }

    /// Ends the runner and shuts the simulator down, so nothing of the machine runs. The state is off from the moment
    /// the stop is asked. So a start that comes meanwhile boots the simulator again once it's down (`boot` waits), and
    /// no tick asks for another shutdown.
    func stop(_ done: @escaping () -> Void) {
        if state == .starting {   // that boot gives up at its next step
            boots += 1
            ready.flush(VMError("\(machine.name) was shut down while it started."))
        }
        Lifecycle.move(&state, to: .off)
        let down = shutDown()
        Task {
            await down.value
            log("shut down")
            done()
        }
    }

    /// Ends the runner (SIGTERM, then SIGKILL) and waits for it, because kelp-vm may end right after. Then it shuts the
    /// simulator down. It first waits for any shutdown or boot already under way.
    private func shutDown() -> Task<Void, Never> {
        let ended = runner, before = shutdown, boot = booting
        runner = nil
        let task = Task {
            await before?.value
            _ = await boot?.result   // the boot reports its own outcome
            if let ended, ended.isRunning {
                let pid = ended.processIdentifier
                await Task.detached { Subprocess.stopTreeNow(pid) }.value
            }
            // simctl fails on a simulator that is already shut down, and that is no failure here.
            do { _ = try await simctl(["shutdown", udid]) } catch  where !"\(error)".contains("current state: Shutdown")
            {
                log("shutting the simulator down: \(error.localizedDescription)")
            } catch {}
        }
        shutdown = task
        return task
    }

    func tick() {   // internal: the tests drive it
        if state == .running, clients > 0 { lastUse = now() }   // a test run is use
        if state == .running, now().timeIntervalSince(lastUse) > Runtime.sleepAfter { stop {} }
    }

    /// The programs that drive a simulator from outside kelp-vm and name its device: `simctl` (installs, launches) and
    /// an XCUITest run.
    private static let clients: Set<String> = ["simctl", "xcodebuild", "xctest"]

    private func ping() async -> Bool {
        let port = port
        return await Task.detached { IOSRunnerClient.ask(port: port, ["op": "ping"])?["text"] as? String == "ok" }.value
    }

    private func simctl(_ args: [String], allowFailure: Bool = false) async throws -> String {
        let out = try await Subprocess.run(
            [xcrun, "simctl"] + args, cwd: "/", env: ProcessInfo.processInfo.environment, timeLimit: 300)
        guard out.status == 0 || allowFailure else {
            throw VMError("simctl \(args.first ?? ""): " + String(decoding: out.stderr, as: UTF8.self))
        }
        return String(decoding: out.stdout, as: UTF8.self)
    }
}
