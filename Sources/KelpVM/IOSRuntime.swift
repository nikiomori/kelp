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
    private var sources: [DispatchSourceProtocol] = []
    /// How it ends once it has left, what time it is, and where xcrun is: the process's exit, the clock's, the
    /// system's; a test's own.
    var exitProcess: () -> Void = { exit(0) }
    var now: () -> Date = { Date() }
    var xcrun = "/usr/bin/xcrun"

    private var udid: String {
        (try? String(contentsOf: folder.appendingPathComponent("udid"), encoding: .utf8))?.trimmingCharacters(
            in: .whitespacesAndNewlines) ?? ""
    }

    init(folder: URL, machine: VMMachine) {
        self.folder = folder
        self.machine = machine
    }

    func listen() {
        // Its lock is held already (main.swift).
        sources.append(
            Control.listen(folder.appendingPathComponent("ctl.sock").path) { [weak self] fd in
                guard let self else { return }
                Control.serve(fd, handle: handle, reply: reply)
            })
        sources += Control.run(
            tick: { [weak self] in self?.tick() }, leave: { [weak self] in self?.stop { self?.exitProcess() } })
        log("ready: \(machine.name) (iOS \(udid)), off")
    }

    private func reply(_ fd: Int32, _ error: String?) {
        let up = [.running, .starting].contains(state)
        let using = state == .running ? Usage.clients(of: udid, programs: Self.clients) : 0   // kelpd's budget sleeps an idle one only
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
                if error == nil { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: simulator) }
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
        do {
            _ = try await simctl(["boot", udid], allowFailure: true)
            _ = try await simctl(["bootstatus", udid, "-b"])
            // No build folder at all (a making cut short) is told as a runner not built, not as a missing folder.
            let products = folder.appendingPathComponent("dd/Build/Products")
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
            if let logFile = try? FileHandle(forWritingTo: out) {
                process.standardOutput = logFile
                process.standardError = logFile
            }
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
            runner?.terminate()
        }
        state = error == nil ? .running : .error
        lastUse = now()
        let waiting = ready
        ready = []
        waiting.forEach { $0(error?.localizedDescription) }
    }

    /// The runner gone and the simulator shut down: nothing of it runs.
    private func stop(_ done: @escaping () -> Void) {
        runner?.terminate()
        runner = nil
        Task {
            _ = try? await simctl(["shutdown", udid], allowFailure: true)
            state = .off
            log("shut down")
            done()
        }
    }

    func tick() {   // internal: the tests drive it
        if state == .running, Usage.clients(of: udid, programs: Self.clients) > 0 { lastUse = now() }   // a test run is use
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
