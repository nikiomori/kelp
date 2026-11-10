import Core
import Foundation

/// An iOS machine: a simulator of the user's Xcode ("Kelp <name>", in the default device set: xcodebuild sees no other), and
/// Kelp's runner in it (`IOSRunner`, built into the machine's folder), which agents' commands reach on the Mac's loopback.
/// A simulator can't be paused or saved: idle 10 minutes, it shuts down; the next command boots it again (10–25 s).
@MainActor
final class IOSRuntime {
    let folder: URL, machine: VMMachine
    private(set) var state: VMState = .off
    private var runner: Process?
    private var port = 0
    private var lastUse = Date()
    private var ready: [(String?) -> Void] = []
    /// The last shutdown asked of the simulator: a boot waits for it (booted under it, it would be shut down again).
    private var shutdown: Task<Void, Never>?
    private var sources: [DispatchSourceProtocol] = []
    /// How it ends once it has left, what time it is, and where xcrun is: the process's exit, the clock's, the
    /// system's; a test's own.
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
        // Its lock is held already (main.swift).
        sources.append(
            Control.listen(VMFolder(folder).control.path) { [weak self] fd in
                guard let self else { return }
                Control.serve(fd, handle: handle, reply: reply)
            })
        sources += Control.run(
            tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.stop { self?.exitProcess() } })
        log("ready: \(machine.name) (iOS \(udid)), off")
    }

    /// In use: what drives the simulator from outside (kelpd's memory budget sleeps an idle machine only).
    private var using: Int { state == .running ? Usage.clients(of: udid, programs: Self.clients) : 0 }

    private func reply(_ fd: Int32, _ error: String?) {
        let up = state.isUp   // never paused: a simulator can't be
        var answer = VMHelper.Reply(
            state: state, connections: using, memoryMiB: up ? machine.memoryMiB : nil, error: error,
            serial: state == .running ? udid : nil)
        answer.port = state == .running ? port : nil
        Control.write(fd, answer)
    }

    func handle(_ request: VMHelper.Request, _ done: @escaping (String?) -> Void) {   // internal: the tests drive it
        switch request.op {
        case .status: done(nil)
        case .start where request.begins:
            lastUse = now()
            wake { _ in }
            done(nil)   // kelpd's wake: answered as it starts
        case .start:
            lastUse = now()
            wake(done)
        // The budget's (`if-idle`): asked of one that was idle a moment ago, refused if it's in use by now.
        case .sleep where Lifecycle.refusesSleep(request, inUse: using > 0): done("\(machine.name) is in use.")
        case .sleep, .stop:
            stop {
                done(nil)
                self.exitProcess()
            }   // a simulator keeps no running state to save; the next start is a new kelp-vm
        case .share: done("An iOS machine shares no folders: kelp vm install takes an app from here.")
        case .screen: done("Typing into the screen is a macOS machine's.")
        case .show:
            lastUse = now()
            wake { error in
                let simulator = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", self.udid]
                if error == nil {
                    do { _ = try Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: simulator) } catch {
                        log("opening Simulator: \(error.localizedDescription)")
                    }
                }
                done(error)
            }
        case .quit:
            done(nil)
            stop { self.exitProcess() }
        }
    }

    private func wake(_ done: @escaping (String?) -> Void) {
        switch state {
        case .running: done(nil)
        case .starting: ready.append(done)
        default:
            ready.append(done)
            state = .starting
            Task { await boot() }
        }
    }

    /// The simulator booted (a no-op when it already is), then the runner started in it and answering.
    private func boot() async {
        await shutdown?.value
        Lifecycle.endLeftover(in: folder, "runner")   // a kelp-vm that was killed left its runner; the simulator is taken as it is
        do {
            _ = try await simctl(["boot", udid], allowFailure: true)
            _ = try await simctl(["bootstatus", udid, "-b"])
            // No build folder at all (a making cut short) is told as a runner not built, not as a missing folder.
            let products = VMFolder(folder).runnerBuild.appendingPathComponent("Build/Products")
            let built =
                FileManager.default.fileExists(atPath: products.path)
                ? try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil) : []
            guard let xctestrun = built.first(where: { $0.pathExtension == "xctestrun" }) else {
                throw VMError("Kelp's runner isn't built in \(machine.name)'s folder: make the machine again.")
            }
            port = AndroidRuntime.freePort(from: 8700)
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
                    MainActor.assumeIsolated {   // the main queue
                        guard let self, self.runner === ended else { return }
                        self.runner = nil
                        if self.state == .running {
                            self.state = .off
                            log("the runner ended: see runner.log")
                        }
                    }
                }
            }
            try process.run()
            runner = process
            Lifecycle.remember(process, in: folder, as: "runner")
            let since = Date()
            while Date().timeIntervalSince(since) < 180 {
                if await ping() { return started(nil) }
                guard runner != nil else {
                    throw VMError("Kelp's runner quit: see runner.log in \(machine.name)'s folder.")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw VMError("Kelp's runner didn't answer in 3 minutes.")
        } catch { started(error) }
    }

    private func started(_ error: Error?) {
        if let error {
            log("start failed: \(error.localizedDescription)")
            _ = shutDown()   // half started, its simulator would stay booted: no tick looks at one that isn't running
        }
        state = error == nil ? .running : .error
        lastUse = now()
        let waiting = ready
        ready = []
        waiting.forEach { $0(error?.localizedDescription) }
    }

    /// The runner gone and the simulator shut down: nothing of it runs. Off from the moment it's asked: a start that
    /// comes meanwhile boots it again once it's down (`boot` waits), and no tick asks for another shutdown.
    private func stop(_ done: @escaping () -> Void) {
        state = .off
        let down = shutDown()
        Task {
            await down.value
            log("shut down")
            done()
        }
    }

    /// Ends the runner (SIGTERM, then SIGKILL, waited for: kelp-vm may end right after) and shuts the simulator down,
    /// after a shutdown already under way.
    private func shutDown() -> Task<Void, Never> {
        let ended = runner, before = shutdown
        runner = nil
        let task = Task {
            await before?.value
            if let ended, ended.isRunning {
                let pid = ended.processIdentifier
                await Task.detached { Subprocess.stopTreeNow(pid) }.value
            }
            // One shut down already says so, which is no failure.
            do { _ = try await simctl(["shutdown", udid]) } catch  where !"\(error)".contains("current state: Shutdown")
            {
                log("shutting the simulator down: \(error.localizedDescription)")
            } catch {}
        }
        shutdown = task
        return task
    }

    func tick() {   // internal: the tests drive it
        if state == .running, using > 0 { lastUse = now() }   // a test run is use
        if state == .running, now().timeIntervalSince(lastUse) > Runtime.sleepAfter { stop {} }
    }

    /// What drives a simulator from outside kelp-vm, naming its device: `simctl` (installs, launches), an XCUITest run.
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
